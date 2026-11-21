---@module 'tasks_nvim.routine_after'
-- @scans-data: the folders it lists are task vaults, never the files of this plugin
---@brief Routines that start after something is finished (`repeat_after`): what they wait for, and starting them.
---@description
--- A routine may wait with its first round until a task, a learning path or a point of a path is finished:
--- `repeat_after: <area>/<slug>` (a task or a path; finished = in `Backlog/`) or `repeat_after: <area>/<slug>#<key>`
--- (the point of that key in the path's `## Lernpunkte`; finished = closed with at least one leaf learned or seen, a
--- point dropped in full starts nothing). While it waits it has no `due` and `check` says nothing about that.
---
--- `settle` writes the first round: `due`, `start` and `remind` = the day it was finished plus the first interval of
--- `repeat` (`model.first_round_due`; for a task or path, the date in its Backlog file name; for a point, the day of
--- the write). `repeat_after` stays in the file (it says where the routine came from); the next round drops it. A
--- routine that has a `due` already is never touched again.
---
--- Callers: `done_flow.run` (a finished task, and the point it was promoted from), `paths.point` (a point set),
--- `paths.close` (a path finished). `check` asks `resolve` to name a reference that is nowhere
--- (`repeat-after-unknown`) and a routine whose start was missed (`repeat-after-missed`).
---
--- Not its job: the next rounds (`done_flow`), the ladder (`model.next_round_due`).

local fsio = require("tasks_nvim.fsio")
local lernbaum = require("tasks_nvim.lernbaum")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.RoutineAfterState
---@field state "open"|"finished"|"unknown"
---@field date? string   # The day it was finished (`finished`).
---@field why? string    # What is missing (`unknown`).

---The day a finished file was finished: the date of its Backlog name (a folder carries it on the folder).
---@param path string
---@return string|nil
local function finished_on(path)
  return model.done_date(path) or model.done_date(fsio.dirname(path))
end

---Whether a point of a tree is finished: closed, and something of it learned or seen.
---@param tree Tasks.LernTree
---@param key string
---@return boolean|nil finished  # nil: no point of that key.
local function point_finished(tree, key)
  local node = tree.by_key[key]
  if not node then
    return nil
  end
  return node.closed and (node.progress.learned + node.progress.seen) > 0
end

---What a `repeat_after` reference stands at now.
---@param ref string
---@param root string
---@param today string
---@return Tasks.RoutineAfterState
function M.resolve(ref, root, today)
  if not model.is_repeat_after(ref) then
    return { state = "unknown", why = "no id and no point of a path" }
  end
  local scan = require("tasks_nvim.scan")
  local paths = require("tasks_nvim.paths")
  local id, key = ref:match("^([^#]+)#(.+)$")
  id = id or ref
  if not key then
    if scan.find(id, { root = root }) or paths.find(id, { root = root }) then
      return { state = "open" }
    end
    local done = scan.find_done(id, { root = root })
    if done then
      return { state = "finished", date = finished_on(done.path) or today }
    end
    return { state = "unknown", why = "no task or path " .. id }
  end
  -- a point: of an open path (finished today, when the write is made), or of a path that was closed
  local open = paths.find(id, { root = root })
  local tree, date = open and open.tree, today
  if not open then
    local done = scan.find_done(id, { root = root })
    local text = done and fsio.read(done.path)
    if not done or type(text) ~= "string" then
      return { state = "unknown", why = "no path " .. id }
    end
    -- the section is found by its heading: the frontmatter above it does not matter
    tree = lernbaum.parse(text)
    date = finished_on(done.path) or today
  end
  local finished = tree and point_finished(tree, key)
  if finished == nil then
    return { state = "unknown", why = ("no point #%s in %s"):format(key, id) }
  end
  return finished and { state = "finished", date = date } or { state = "open" }
end

---Whether a reference is about `id` (the id itself, or a point of it).
---@param ref string
---@param ids table<string, true>
---@return boolean
local function about(ref, ids)
  return ids[ref] == true or ids[ref:match("^([^#]+)#") or ""] == true
end

---Start the routines that wait for something now finished: each open task with `repeat_after`, a valid `repeat` and no
---`due` gets its first round (`due`, `start`, `remind`). `opts.ids` limits it to the references of those ids (a task,
---a path, `path#key` counts for its path); without it every waiting routine is looked at.
---`opts.open` is a scan of the open tasks the caller made after the finish (a batch scans once); without it `settle`
---scans itself.
---@param opts { root?: string, today?: string, ids?: string[], index?: boolean, dry_run?: boolean, open?: Tasks.Task[] }
---@return { id: string, due: string, after: string }[] started
---@return string[] notes  # A routine that could not be written.
function M.settle(opts)
  local started, notes = {}, {}
  local root = vault.root(opts)
  if not root then
    return started, notes
  end
  local filter
  if opts.ids then
    filter = {}
    for _, id in ipairs(opts.ids) do
      filter[id] = true
    end
    if next(filter) == nil then
      return started, notes
    end
  end
  local today = opts.today or model.today()
  local open = opts.open or require("tasks_nvim.scan").open_tasks({ root = root }) or {}
  local mutate = require("tasks_nvim.mutate")
  for _, t in ipairs(open) do
    local ref = t.repeat_after
    if
      type(ref) == "string"
      and model.is_repeat_after(ref)
      and model.is_repeat_steps(t.repeat_every)
      and not model.is_date(t.due)
      and (not filter or about(ref, filter))
    then
      local r = M.resolve(ref, root, today)
      local due = r.state == "finished" and model.first_round_due(t, r.date) or nil
      if due then
        if opts.dry_run then
          started[#started + 1] = { id = t.id, due = due, after = ref }
        else
          local res, err = mutate.set(
            t.id,
            { due = due, start = due, remind = due },
            { root = root, today = today, index = opts.index }
          )
          if res then
            started[#started + 1] = { id = t.id, due = due, after = ref }
          else
            notes[#notes + 1] = ("the routine %s (after %s) was not started: %s"):format(
              t.id,
              ref,
              tostring(err)
            )
          end
        end
      end
    end
  end
  table.sort(started, function(a, b)
    return a.id < b.id
  end)
  return started, notes
end

return M
