---@module 'tasks_nvim.projects'
---@brief Project files: one Markdown file per undertaking that groups several plans, under `<area>/ROADMAP/projects/`.
---@description
--- The levels are fixed: a project holds plans, a plan holds tasks, the steps of a task are its subtasks. A project file
--- has the shape of a plan file (`title`, `status`, `areas`, `target`, `phase_order`, `gate`, goal, definition of done,
--- decisions) and holds NO list either: a plan names its project (`project: <area>/<slug>`, optionally `phase:` of the
--- project's `phase_order`), a task of the project itself names it with `project:` instead of `plan:`. What a project
--- consists of is derived, so two machines never collide on a list in the project file.
---
--- The file is read by `tasks_nvim.plans` (`parse` with `kind = "project"`); this module lists them, names their
--- members and adds up their progress (`rollup`).
---
--- Not its job: finishing a project (the done chain), the contract documents, the views.

local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@type string[]
M.STATUSES = plans.STATUSES

---Read one project file from disk (always returns a file; a broken one carries `errors`).
---@param path string
---@param ctx { area: string, slug?: string, location?: "roadmap"|"backlog", link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile
function M.from_file(path, ctx)
  return plans.from_file(path, vim.tbl_extend("force", { kind = "project" }, ctx))
end

---The open projects of an area (`ROADMAP/projects/*.md`), by slug.
---@param area string
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile[]|nil projects
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
  local dir = vault.projects_dir(root, area)
  local out = {}
  if not fsio.is_dir(dir) then
    return out, {}
  end
  local escape = vault.leaves(root, dir)
  if escape then
    return out, { escape }
  end
  local resolver = opts.link_resolver or wikilinks.resolver(root)
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.md$") then
      out[#out + 1] = M.from_file(dir .. "/" .. name, { area = area, link_resolver = resolver })
    end
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  return out, {}
end

---Every open project of the vault, areas in name order.
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile[]|nil projects
---@return string|nil err
function M.all(opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local out = {}
  local resolver = opts.link_resolver or wikilinks.resolver(root)
  for _, a in ipairs(vault.areas(root)) do
    for _, project in ipairs(M.area(a.name, { root = root, link_resolver = resolver }) or {}) do
      out[#out + 1] = project
    end
  end
  return out, nil
end

---An open project by id.
---@param id string
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile|nil project
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
  -- not an area, or one spelled in another case: the same refusal as `plans.find`
  if not vault.has_area(root, area) then
    return nil, "no such open project: " .. id
  end
  local path = vault.project_path(root, area, slug)
  if not fsio.is_file(path) then
    return nil, "no such open project: " .. id
  end
  return M.from_file(path, {
    area = area,
    slug = slug,
    link_resolver = opts.link_resolver or wikilinks.resolver(root),
  }),
    nil
end

---The open plan files that belong to a project (`project: <id>` in the plan file).
---@param project_id string
---@param files Tasks.PlanFile[]
---@return Tasks.PlanFile[]
function M.plans_of(project_id, files)
  local out = {}
  for _, f in ipairs(files) do
    if f.project == project_id then
      out[#out + 1] = f
    end
  end
  return out
end

---The open tasks that belong to a project itself (`project: <id>`), not through a plan.
---@param project_id string
---@param tasks Tasks.Task[]
---@return Tasks.Task[]
function M.members(project_id, tasks)
  local out = {}
  for _, t in ipairs(tasks) do
    if t.project == project_id then
      out[#out + 1] = t
    end
  end
  return out
end

---A finished item of a Backlog is a plan file (a closed plan lands in `Backlog/FEATURES/`) when `plans.close` marked it
---(`closed_kind: plan`). A plan closed before the mark existed is told by the keys only a plan file has (`areas`,
---`phase_order`, `gate`, `target`); a finished task never has them.
---@param item Tasks.Task
---@return boolean
function M.is_finished_plan(item)
  local meta = item.meta or {}
  if meta.closed_kind ~= nil then
    return meta.closed_kind == "plan"
  end
  return meta.areas ~= nil or meta.phase_order ~= nil or meta.gate ~= nil or meta.target ~= nil
end

---Every finished item of every area's Backlog (finished tasks and closed plan files), through the parse cache.
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.Task[]
function M.finished_items(opts)
  opts = opts or {}
  local root = vault.root(opts)
  local out = {}
  if not root then
    return out
  end
  local resolver = opts.link_resolver or wikilinks.resolver(root)
  for _, a in ipairs(vault.areas(root)) do
    for _, item in ipairs(scan.backlog(a.name, { root = root, link_resolver = resolver }) or {}) do
      out[#out + 1] = item
    end
  end
  return out
end

---@class Tasks.ProjectRollup
---@field plans_total integer   # The plans of the project, open and finished.
---@field plans_done integer    # The finished ones.
---@field plans_parked integer  # The open ones with status `parked`.
---@field tasks_open integer    # Open tasks of the project: in one of its plans, or its own.
---@field tasks_done integer    # Finished tasks of the same.
---@field own_open integer      # Open tasks that name the project itself (`project:`).
---@field days_open number      # Their effort in days (what carries an effort).
---@field plan_ids string[]     # The ids of the open plans of the project, sorted.

---What a project amounts to: its plans (open files, closed ones in the Backlogs) and the tasks of those plans plus its
---own. `ctx.plans` are the open plan files and `ctx.open` the open tasks of the whole vault; `ctx.finished` the finished
---items of the Backlogs (`finished_items`, made here when not given: pass it when rolling up several projects).
---@param project Tasks.PlanFile
---@param ctx { plans: Tasks.PlanFile[], open: Tasks.Task[], finished?: Tasks.Task[], root?: string }
---@return Tasks.ProjectRollup
function M.rollup(project, ctx)
  local finished = ctx.finished or M.finished_items({ root = ctx.root })
  local member_ids, plan_ids = {}, {}
  local out = { plans_total = 0, plans_done = 0, plans_parked = 0 }
  for _, f in ipairs(M.plans_of(project.id, ctx.plans)) do
    member_ids[f.id] = true
    plan_ids[#plan_ids + 1] = f.id
    out.plans_total = out.plans_total + 1
    if f.status == "parked" then
      out.plans_parked = out.plans_parked + 1
    end
  end
  table.sort(plan_ids)
  for _, item in ipairs(finished) do
    if item.project == project.id and M.is_finished_plan(item) then
      member_ids[item.id] = true
      out.plans_total = out.plans_total + 1
      out.plans_done = out.plans_done + 1
    end
  end
  local open = {}
  out.own_open = 0
  for _, t in ipairs(ctx.open) do
    if t.project == project.id then
      open[#open + 1] = t
      out.own_open = out.own_open + 1
    elseif t.plan and member_ids[t.plan] then
      open[#open + 1] = t
    end
  end
  out.tasks_open = #open
  out.tasks_done = 0
  for _, item in ipairs(finished) do
    if
      not M.is_finished_plan(item)
      and (item.project == project.id or (item.plan and member_ids[item.plan]))
    then
      out.tasks_done = out.tasks_done + 1
    end
  end
  local days = 0
  for _, t in ipairs(open) do
    days = days + (model.effort_days(t.effort) or 0)
  end
  out.days_open = days
  out.plan_ids = plan_ids
  return out
end

---Finish a project: `status: done`, moved to `Backlog/FEATURES/YYYY-MM-DD_<slug>.md` with a row in the Backlog README, as
---a plan is (`plans.close`). Whether the project may be finished is the caller's judgement (`done_flow.close_projects`).
---@param id string
---@param opts? { root?: string, date?: string, today?: string, checkpoint_dir?: string }
---@return { id: string, from: string, to: string, readme: string }|nil result
---@return string|nil err
function M.close(id, opts)
  return plans.close(id, vim.tbl_extend("force", opts or {}, { kind = "project" }))
end

return M
