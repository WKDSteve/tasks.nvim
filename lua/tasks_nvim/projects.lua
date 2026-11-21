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
---@param ctx { area: string, slug?: string, location?: "roadmap"|"backlog", folder?: boolean, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile
function M.from_file(path, ctx)
  return plans.from_file(path, vim.tbl_extend("force", { kind = "project" }, ctx))
end

---The open projects of an area (`ROADMAP/projects/<slug>.md` and `ROADMAP/projects/<slug>/<slug>.md`), by slug.
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
  for _, e in ipairs(vault.plan_files(dir)) do
    out[#out + 1] = M.from_file(
      e.path,
      { area = area, slug = e.slug, folder = e.folder, link_resolver = resolver }
    )
  end
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
  local path, folder = vault.resolve_plan(root, "project", area, slug)
  if not path then
    return nil, folder --[[@as string]]
  end
  return M.from_file(path, {
    area = area,
    slug = slug,
    folder = folder == true,
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

---The open learning paths of a project (`project: <id>` in the path file).
---@param project_id string
---@param files Tasks.PlanFile[]  # Open path files (`paths.all`).
---@return Tasks.PlanFile[]
function M.paths_of(project_id, files)
  return M.plans_of(project_id, files)
end

---@class Tasks.PathRow
---@field id string
---@field title string
---@field status string
---@field points integer     # Leaves of `## Lernpunkte`, dropped ones included (0 for a finished path).
---@field open integer       # Open (and blocked) leaves.
---@field percent integer    # The progress (`lernlevel.percent`); 100 for a finished path.
---@field done boolean       # Finished (closed into the Backlog).

---One row of a learning path: what `tasks paths` lists and a project's overview shows.
---@param f Tasks.PlanFile  # An open path file (`paths.find`, `paths.area`).
---@return Tasks.PathRow
function M.path_row(f)
  local tree = f.tree
  local points, open, percent = 0, 0, 0
  if tree then
    points, open = tree.progress.total, tree.progress.open
    percent = require("tasks_nvim.lernlevel").percent(tree)
  end
  return {
    id = f.id,
    title = f.title,
    status = f.status or "-",
    points = points,
    open = open,
    percent = percent,
    done = false,
  }
end

---The rows of the paths of a project: its open paths (`ctx.paths`), then the finished ones of the Backlogs
---(`closed_kind: path`, at 100 %), in id order each.
---@param project_id string
---@param path_files Tasks.PlanFile[]
---@param finished Tasks.Task[]
---@return Tasks.PathRow[]
function M.path_rows(project_id, path_files, finished)
  local rows = {}
  for _, f in ipairs(M.paths_of(project_id, path_files)) do
    rows[#rows + 1] = M.path_row(f)
  end
  table.sort(rows, function(a, b)
    return a.id < b.id
  end)
  local done = {}
  for _, item in ipairs(finished) do
    if item.project == project_id and M.finished_kind(item) == "path" then
      done[#done + 1] = {
        id = item.id,
        title = item.title,
        status = "done",
        points = 0,
        open = 0,
        percent = 100,
        done = true,
      }
    end
  end
  table.sort(done, function(a, b)
    return a.id < b.id
  end)
  vim.list_extend(rows, done)
  return rows
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

---Which project a task belongs to: the one it names itself (`project:`), else the one its plan names.
---@param task Tasks.Task
---@param plan_projects table<string, string>  # Plan id -> project id (`plan_projects`).
---@return string|nil
function M.project_of(task, plan_projects)
  return task.project or (task.plan and plan_projects[task.plan]) or nil
end

---Plan id -> the project it names, over the open plan files.
---@param files Tasks.PlanFile[]
---@return table<string, string>
function M.plan_projects(files)
  local out = {}
  for _, f in ipairs(files) do
    if f.project then
      out[f.id] = f.project
    end
  end
  return out
end

---The tasks of the projects `ids`: in one of their plans, or their own.
---@param tasks Tasks.Task[]
---@param ids string[]
---@param files Tasks.PlanFile[]  # The open plan files.
---@return Tasks.Task[]
function M.filter(tasks, ids, files)
  local want = {}
  for _, id in ipairs(ids) do
    want[id] = true
  end
  local plan_projects = M.plan_projects(files)
  local out = {}
  for _, t in ipairs(tasks) do
    local project = M.project_of(t, plan_projects)
    if project and want[project] then
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

---What a finished item of a Backlog is: `"plan"`, `"project"`, `"path"` (told by `closed_kind`) or `"task"`.
---@param item Tasks.Task
---@return "plan"|"project"|"path"|"task"
function M.finished_kind(item)
  local meta = item.meta or {}
  if meta.closed_kind == "project" or meta.closed_kind == "path" then
    return meta.closed_kind
  end
  return M.is_finished_plan(item) and "plan" or "task"
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
---@field paths_total? integer  # Its learning paths, open and finished (only when `ctx.paths` was given).
---@field paths_done? integer   # The finished ones.
---@field paths_percent? integer  # The mean progress of its paths (a finished one counts 100 %); 0 without paths.

---What a project amounts to: its plans (open files, closed ones in the Backlogs) and the tasks of those plans plus its
---own. `ctx.plans` are the open plan files and `ctx.open` the open tasks of the whole vault; `ctx.finished` the finished
---items of the Backlogs (`finished_items`, made here when not given: pass it when rolling up several projects).
---`ctx.paths` (the open path files) adds its learning paths (`paths_total`, `paths_done`, `paths_percent`).
---@param project Tasks.PlanFile
---@param ctx { plans: Tasks.PlanFile[], open: Tasks.Task[], finished?: Tasks.Task[], root?: string, paths?: Tasks.PlanFile[] }
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
    -- a finished project or learning path of the project is no finished task of it
    if
      M.finished_kind(item) == "task"
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
  if ctx.paths then
    local rows = M.path_rows(project.id, ctx.paths, finished)
    local sum, done = 0, 0
    for _, r in ipairs(rows) do
      sum = sum + r.percent
      done = done + (r.done and 1 or 0)
    end
    out.paths_total, out.paths_done = #rows, done
    out.paths_percent = #rows > 0 and math.floor(sum / #rows) or 0
  end
  return out
end

---One cell of a Markdown table: no pipe, no line break.
---@param text any
---@return string
local function cell(text)
  return (fsio.clean(tostring(text or "")):gsub("|", "/"))
end

---The words of the generated overview, by language (the reader of the level lines does the same, `lernlevel.WORDS`).
---@type table<"de"|"en", table<string, string>>
M.WORDS = {
  de = {
    stages = "Etappen",
    done_when = "Fertig, wenn",
    head_plans = "| Etappe | Plan | Status | Offen | Tage |",
    no_plans_row = "| - | noch keine Pläne | - | 0 | - |",
    none = "Noch keine Pläne und keine Lernpfade.",
    head_paths = "| Lernpfad | Status | Punkte | Offen | Fortschritt |",
    own = "Eigene Tasks des Projekts: %d offen.",
  },
  en = {
    stages = "Stages",
    done_when = "Done when",
    head_plans = "| Stage | Plan | Status | Open | Days |",
    no_plans_row = "| - | no plans yet | - | 0 | - |",
    none = "No plans and no learning paths yet.",
    head_paths = "| Learning path | Status | Points | Open | Progress |",
    own = "Own tasks of the project: %d open.",
  },
}

---Words that are German or English and (almost) never both; `lang_of` counts them.
local MARKS = {
  de = "und der die das ist nicht mit für ein eine wenn oder den dem von auf sind wird alle je ziel abgrenzung "
    .. "lernpfade lernpfad takt entscheidungen notizen offen noch keine",
  en = "and the is not with for an when or to are will all per goal scope decisions notes open yet no",
}
local MARK_SETS = {}
for lang, list in pairs(MARKS) do
  MARK_SETS[lang] = {}
  for w in list:gmatch("%S+") do
    MARK_SETS[lang][w] = true
  end
end

---The language of a hand-written document: German or English by the words of its text outside the generated blocks
---(an umlaut counts for German); nil when it says neither (or both equally).
---@param text string
---@return "de"|"en"|nil
function M.lang_of(text)
  local kept, inside = {}, false
  for line in (text or ""):gmatch("[^\n]*") do
    if line:find("<!-- GENERATED:plan scope=", 1, true) then
      inside = true
    elseif line:find("<!-- GENERATED:plan end -->", 1, true) then
      inside = false
    elseif not inside then
      kept[#kept + 1] = line
    end
  end
  local body = table.concat(kept, " "):lower()
  local score = { de = 0, en = 0 }
  for _ in body:gmatch("[äöüß]") do
    score.de = score.de + 1
  end
  for w in body:gmatch("%a+") do
    for lang, set in pairs(MARK_SETS) do
      if set[w] then
        score[lang] = score[lang] + 1
      end
    end
  end
  if score.de > score.en then
    return "de"
  elseif score.en > score.de then
    return "en"
  end
  return nil
end

---The language of the generated words for a document: its own (`lang_of`), else the vault's marker file (`lang`), else
---German.
---@param text? string  # The document the block stands in.
---@param root? string
---@return "de"|"en"
function M.lang_for(text, root)
  local own = text and M.lang_of(text)
  if own then
    return own
  end
  local marker = root and require("tasks_nvim.vault_marker").read(root)
  return marker and marker.lang or "de"
end

---The overview of a project as the body of a marker block: its plans in the order of its stages (a plan of no listed
---stage last), each with status and what is open, then its learning paths (`ctx.paths`, the open path files: points,
---open ones, progress; finished ones at 100 %), then the tasks of the project itself. Open plans come from the plan
---files, finished ones from the Backlogs. A project with paths and no plans shows no table of plans. Pure given its
---inputs. The words are `ctx.lang`'s (`WORDS`; English without one: pass `lang_for`).
---@param project Tasks.PlanFile
---@param ctx { plans: Tasks.PlanFile[], open: Tasks.Task[], finished?: Tasks.Task[], root?: string, paths?: Tasks.PlanFile[], lang?: "de"|"en" }
---@return string
function M.overview(project, ctx)
  local w = M.WORDS[ctx.lang or "en"] or M.WORDS.en
  local finished = ctx.finished or M.finished_items({ root = ctx.root })
  local rows = {}
  for _, f in ipairs(M.plans_of(project.id, ctx.plans)) do
    local n, days = 0, 0
    for _, t in ipairs(ctx.open) do
      if t.plan == f.id then
        n = n + 1
        days = days + (model.effort_days(t.effort) or 0)
      end
    end
    rows[#rows + 1] = {
      id = f.id,
      title = f.title,
      phase = f.phase,
      status = f.status or "-",
      open = n,
      days = days,
    }
  end
  for _, item in ipairs(finished) do
    if item.project == project.id and M.is_finished_plan(item) then
      rows[#rows + 1] = {
        id = item.id,
        title = item.title,
        phase = item.phase,
        status = "done",
        open = 0,
        days = 0,
      }
    end
  end
  local rank = {}
  for i, name in ipairs(project.phase_order or {}) do
    rank[name] = i
  end
  local function key(r)
    return r.phase and rank[r.phase] or (#(project.phase_order or {}) + 1)
  end
  table.sort(rows, function(a, b)
    if key(a) ~= key(b) then
      return key(a) < key(b)
    end
    return a.id < b.id
  end)
  local lines = { ("**%s** (%s)"):format(cell(project.title), project.status or "?") }
  if #(project.phase_order or {}) > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = w.stages .. ": " .. table.concat(project.phase_order, " > ")
  end
  if project.target then
    lines[#lines + 1] = ""
    lines[#lines + 1] = w.done_when .. ": " .. cell(project.target)
  end
  local path_rows = ctx.paths and M.path_rows(project.id, ctx.paths, finished) or {}
  if #rows == 0 and #path_rows == 0 and ctx.paths then
    -- the paths were looked for too: neither a table of plans nor one of paths
    vim.list_extend(lines, { "", w.none })
  elseif #rows > 0 or #path_rows == 0 then
    vim.list_extend(lines, { "", w.head_plans, "|---|---|---|---|---|" })
    for _, r in ipairs(rows) do
      lines[#lines + 1] = ("| %s | `%s` %s | %s | %d | %s |"):format(
        cell(r.phase or "-"),
        cell(r.id),
        cell(r.title),
        cell(r.status),
        r.open,
        r.days > 0 and require("tasks_nvim.estimate").fmt_days(r.days) or "-"
      )
    end
    if #rows == 0 then
      lines[#lines + 1] = "| - | no plans yet | - | 0 | - |"
    end
  end
  if #path_rows > 0 then
    vim.list_extend(lines, { "", w.head_paths, "|---|---|---|---|---|" })
    for _, r in ipairs(path_rows) do
      lines[#lines + 1] = ("| `%s` %s | %s | %s | %s | %d %% |"):format(
        cell(r.id),
        cell(r.title),
        cell(r.status),
        r.done and "-" or tostring(r.points),
        r.done and "-" or tostring(r.open),
        r.percent
      )
    end
  end
  local own = M.members(project.id, ctx.open)
  lines[#lines + 1] = ""
  lines[#lines + 1] = w.own:format(#own)
  return table.concat(lines, string.char(10)) .. string.char(10)
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
