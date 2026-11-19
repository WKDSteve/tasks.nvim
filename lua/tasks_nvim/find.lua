---@module 'tasks_nvim.find'
---@brief Find tasks by what they carry: the refs they name, over open and finished tasks alike.
---@description
--- `call find { refs = [...] }` (the contract method `find`) and the callers inside the engine (`intent`) ask here. A match
--- is a task whose `refs:` holds the ref exactly, in `ROADMAP/` or in the `Backlog/` of any area: the answer is the id, the
--- area, the status and where it is (`open` or `done`), never a path.
---
--- Namespaced refs (`<ns>:<key>`, a registered namespace such as `testing-finding` or `rules-target`) are what other
--- tools put into `refs:` to find "their" task again without a database; this is the lookup for them.
---
--- Not its job: writing a ref (`mutate`, the ops door), judging one (`ops.bad_ref`).

local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---The most refs one call may ask for.
M.MAX_REFS = 50

---@class Tasks.FindMatch
---@field ref string       # the ref that matched
---@field id string
---@field area string
---@field status string
---@field location "open"|"done"   # A meeting: `open` while planned, `done` when done or cancelled.
---@field kind "task"|"meeting"
---@field title? string

---The tasks that name any of `refs`, open ones first, then by id, a task once per ref it holds; and the meetings that
---name one of them (in `tasks:` or behind a follow-up, `-> <id>`), unless `opts.tasks_only`.
---@param refs string[]
---@param opts? { root?: string, tasks_only?: boolean }
---@return Tasks.FindMatch[]
function M.by_refs(refs, opts)
  local root = vault.root(opts)
  local out = {}
  if not root then
    return out
  end
  local wanted = {}
  for _, ref in ipairs(refs) do
    if type(ref) == "string" and ref ~= "" then
      wanted[ref] = true
    end
  end
  if next(wanted) == nil then
    return out
  end
  local scan_opts = { root = root }
  ---@param tasks Tasks.Task[]|nil
  ---@param location "open"|"done"
  local function take(tasks, location)
    for _, t in ipairs(tasks or {}) do
      local seen = {}
      for _, ref in ipairs(t.refs or {}) do
        if wanted[ref] and not seen[ref] then
          seen[ref] = true
          out[#out + 1] = {
            ref = ref,
            id = t.id,
            area = t.area,
            status = type(t.status) == "string" and t.status or "unknown",
            location = location,
            kind = "task",
            title = t.title,
          }
        end
      end
    end
  end
  for _, area in ipairs(vault.area_names(root)) do
    take(scan.area(area, scan_opts), "open")
    take(scan.backlog(area, scan_opts), "done")
  end
  if not (opts and opts.tasks_only) then
    for _, m in ipairs(require("tasks_nvim.meetings").all({ root = root }) or {}) do
      local named = {}
      for _, id in ipairs(m.tasks) do
        named[id] = true
      end
      for _, f in ipairs(m.followups) do
        if f.task then
          named[f.task] = true
        end
      end
      local hits = {}
      for ref in pairs(wanted) do
        if named[ref] then
          hits[#hits + 1] = ref
        end
      end
      table.sort(hits)
      for _, ref in ipairs(hits) do
        out[#out + 1] = {
          ref = ref,
          id = m.id,
          area = m.area,
          status = m.status or "unknown",
          location = m.status == "planned" and "open" or "done",
          kind = "meeting",
          title = m.title,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.location ~= b.location then
      return a.location == "open"
    end
    if a.id ~= b.id then
      return a.id < b.id
    end
    return a.ref < b.ref
  end)
  return out
end

---One task by its id, open first, else the newest finished one.
---@param id string
---@param opts? { root?: string }
---@return { id: string, area: string, status: string, location: "open"|"done", title?: string }|nil
function M.by_id(id, opts)
  local root = vault.root(opts)
  if not root then
    return nil
  end
  local task = scan.find(id, { root = root })
  local location = "open"
  if not task then
    task = scan.find_done(id, { root = root })
    location = "done"
  end
  if not task then
    return nil
  end
  return {
    id = task.id,
    area = task.area,
    status = type(task.status) == "string" and task.status or "unknown",
    location = location,
    title = task.title,
  }
end

return M
