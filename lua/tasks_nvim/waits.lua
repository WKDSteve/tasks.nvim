---@module 'tasks_nvim.waits'
---@brief What the parked tasks wait for: the counts per `waits_for` key, the words for them, the steps of a release.
---@description
--- A task that cannot be worked on because something outside is missing (a machine, a licence, a decision of someone
--- else) is `status: parked` with `waits_for: <key>`. The key is one word of the vault's own (`model.is_waits_for`);
--- a parked task without it was set aside by choice.
---
---  - `summary`: per key how many parked tasks wait for it and in which areas, plus the parked tasks without a reason;
---  - `counts`, `breakdown`, `parked_text`: "30 parked (25 waiting for mac)" for the places that say a number;
---  - `mark`: the short mark of one task in a list (`[waits: mac]`);
---  - `release_steps`: the `batch.set_many` steps that bring every task of one key back to `open`.
---
--- Pure: nothing here reads or writes a file. A key that is no key (`invalid-waits-for` of `check`) is counted apart
--- (`invalid`), never as a reason.

local model = require("tasks_nvim.model")

local M = {}

---@class Tasks.WaitsKey
---@field key string
---@field count integer
---@field areas string[]   # The areas of its tasks, sorted.
---@field ids string[]     # The tasks, sorted.

---@class Tasks.WaitsSummary
---@field parked integer           # Every parked task.
---@field without integer          # Parked without `waits_for`.
---@field invalid integer          # Parked with a `waits_for` that is no key.
---@field keys Tasks.WaitsKey[]    # Most tasks first, then by name.

---The reason a task waits for, when it is parked and names a valid key.
---@param task Tasks.Task
---@return string|nil key
function M.key_of(task)
  if task.status == "parked" and model.is_waits_for(task.waits_for) then
    return task.waits_for
  end
  return nil
end

---The overview of the parked tasks among `tasks`.
---@param tasks Tasks.Task[]
---@return Tasks.WaitsSummary
function M.summary(tasks)
  ---@type Tasks.WaitsSummary
  local out = { parked = 0, without = 0, invalid = 0, keys = {} }
  ---@type table<string, { key: string, count: integer, area_set: table<string, boolean>, ids: string[] }>
  local by_key = {}
  for _, t in ipairs(tasks) do
    if t.status == "parked" then
      out.parked = out.parked + 1
      local key = M.key_of(t)
      if key then
        local entry = by_key[key] or { key = key, count = 0, area_set = {}, ids = {} }
        by_key[key] = entry
        entry.count = entry.count + 1
        entry.area_set[t.area] = true
        entry.ids[#entry.ids + 1] = t.id
      elseif t.waits_for ~= nil then
        out.invalid = out.invalid + 1
      else
        out.without = out.without + 1
      end
    end
  end
  for _, entry in pairs(by_key) do
    local areas = vim.tbl_keys(entry.area_set)
    table.sort(areas)
    table.sort(entry.ids)
    out.keys[#out.keys + 1] =
      { key = entry.key, count = entry.count, areas = areas, ids = entry.ids }
  end
  table.sort(out.keys, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.key < b.key
  end)
  return out
end

---How many parked tasks wait for each key.
---@param tasks Tasks.Task[]
---@return table<string, integer>
function M.counts(tasks)
  local out = {}
  for _, t in ipairs(tasks) do
    local key = M.key_of(t)
    if key then
      out[key] = (out[key] or 0) + 1
    end
  end
  return out
end

---`25 waiting for mac, 3 for licence`: the keys of `counts`, most tasks first. Nil when there is none.
---@param counts? table<string, integer>
---@return string|nil
function M.breakdown(counts)
  local keys = vim.tbl_keys(counts or {})
  if #keys == 0 then
    return nil
  end
  table.sort(keys, function(a, b)
    if counts[a] ~= counts[b] then
      return counts[a] > counts[b]
    end
    return a < b
  end)
  local parts = {}
  for i, key in ipairs(keys) do
    parts[i] = ("%d %s %s"):format(counts[key], i == 1 and "waiting for" or "for", key)
  end
  return table.concat(parts, ", ")
end

---`30 parked`, or `30 parked (25 waiting for mac)` when some of them name a reason.
---@param parked integer
---@param counts? table<string, integer>
---@return string
function M.parked_text(parked, counts)
  local detail = M.breakdown(counts)
  return ("%d parked"):format(parked) .. (detail and (" (" .. detail .. ")") or "")
end

---The mark of a task in a list: `waits: mac`. Nil for a task that names no reason.
---@param task Tasks.Task
---@return string|nil
function M.mark(task)
  local key = M.key_of(task)
  return key and ("waits: " .. key) or nil
end

---The steps that release `key`: every parked task that waits for it goes to `open`; `mutate.set` drops the key in the
---same write. Each step expects the key it was planned from, so a task changed meanwhile is refused, not overwritten.
---@param tasks Tasks.Task[]
---@param key string
---@return Tasks.BatchSetStep[]
function M.release_steps(tasks, key)
  local steps = {}
  for _, t in ipairs(tasks) do
    if M.key_of(t) == key then
      steps[#steps + 1] = {
        id = t.id,
        patch = { status = "open" },
        expect = { key = "waits_for", value = key },
      }
    end
  end
  table.sort(steps, function(a, b)
    return a.id < b.id
  end)
  return steps
end

return M
