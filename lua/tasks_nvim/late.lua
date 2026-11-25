---@module 'tasks_nvim.late'
-- lua/tasks_nvim/late.lua -- a blocker that is due later than the task waiting on it begins (or, without a start, is
-- due): the rule behind the `blocker-late` hint of `check` and the `late_blockers` of a task entry in `tasks-export/1`.
-- Pure over the open tasks; nothing is read or written. `blocked_by` is a hard wait, `after` a soft one: both are
-- named, the kind says which. A finished, unknown or undated blocker is not late; a parked waiting task is left out
-- (it waits on purpose).

local model = require("tasks_nvim.model")

local M = {}

---@class Tasks.LateBlocker
---@field id string        # The blocker.
---@field kind "blocked_by"|"after"
---@field due string       # The blocker's due date.
---@field against "start"|"due"  # The date of the waiting task it is later than.
---@field date string      # That date.

---The blockers of `task` that are due after it begins (its `start`, else its `due`).
---@param task Tasks.Task
---@param by_id table<string, Tasks.Task>  # The open tasks by id.
---@return Tasks.LateBlocker[]
function M.blockers(task, by_id)
  if task.status == "parked" then
    return {}
  end
  local against, date
  if model.is_date(task.start) then
    against, date = "start", task.start
  elseif model.is_date(task.due) then
    against, date = "due", task.due
  else
    return {}
  end
  local out, seen = {}, {}
  for _, kind in ipairs({ "blocked_by", "after" }) do
    for _, id in ipairs(task[kind] or {}) do
      local blocker = by_id[id]
      if
        blocker
        and not seen[id]
        and id ~= task.id
        and model.is_date(blocker.due)
        and blocker.due > date
      then
        seen[id] = true
        out[#out + 1] = { id = id, kind = kind, due = blocker.due, against = against, date = date }
      end
    end
  end
  return out
end

---The late blockers of every open task that has some, by the id of the waiting task.
---@param open Tasks.Task[]
---@return table<string, Tasks.LateBlocker[]>
function M.of_open(open)
  local by_id = {}
  for _, t in ipairs(open) do
    by_id[t.id] = t
  end
  local out = {}
  for _, t in ipairs(open) do
    local late = M.blockers(t, by_id)
    if #late > 0 then
      out[t.id] = late
    end
  end
  return out
end

---The line of `check` for one late blocker of `task`.
---@param task Tasks.Task
---@param late Tasks.LateBlocker
---@return string
function M.message(task, late)
  return ("%s %s is due %s, after this task's %s %s (%s)"):format(
    late.kind,
    late.id,
    late.due,
    late.against,
    late.date,
    task.id
  )
end

return M
