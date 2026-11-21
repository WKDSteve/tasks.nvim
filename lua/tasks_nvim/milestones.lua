---@module 'tasks_nvim.milestones'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Milestones: one Markdown file per milestone under `<area>/ROADMAP/milestones/`, a dated bundle of ids.
---@description
--- A milestone is a fixed set of things to finish by a day: plans, projects, tasks, meetings and learning paths, named
--- by id in `includes:`. It is its own level (decision 2026-11-21), not a project: a project bundles plans and closes
--- itself, a milestone bundles anything and is REACHED. Its file is `<area>/ROADMAP/milestones/<slug>.md` (or
--- `milestones/<slug>/<slug>.md`), its id `<area>/<slug>` shares the namespace of the area with tasks, plans, projects,
--- paths and meetings. It never moves to the Backlog: a reached milestone is an event with a date.
---
--- Frontmatter (flat): `title`, `status` (`planning`, `doing`, `parked`, `done`), `due` (the day it is aimed at),
--- `includes` (ids of this vault), `close` (`auto`, the default, or `manual`), `reached` (written by the engine),
--- `summary`, `created`, `updated`. The body is free text; `## Verlauf` holds one dated line per time it was reached or
--- opened again, written by the engine.
---
--- A member is done when it is finished: a task or a plan, project or path in the Backlog, a meeting `done` or
--- `cancelled`. A milestone of `close: auto` whose members are all done is reached by the engine on the next write that
--- can finish one (`settle`: `status: done`, `reached: <day>`, a line in `## Verlauf`); one of `close: manual` is reached
--- by setting its status to `done`. When a member of a reached milestone is open again, it goes back to `doing`;
--- `reached` stays as its history. A member that exists nowhere never counts as done; nothing points into another vault.
---
--- Not its job: the contract documents (`contract`), the rule check (`check`), the write door (`ops`).

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---The statuses of a milestone (those of a plan file).
---@type string[]
M.STATUSES = { "planning", "doing", "parked", "done" }

---How a milestone is reached: by the engine when its last member is done, or by hand.
---@type string[]
M.CLOSE = { "auto", "manual" }

---The kinds of member a milestone may include.
---@type string[]
M.KINDS = { "task", "plan", "project", "path", "meeting" }

---The most members a milestone names.
M.MAX_INCLUDES = 100

---The headings of the history section (German first: the one a new file gets).
---@type string[]
M.HISTORY = { "## Verlauf", "## History" }

---The keys `set` may change.
---@type string[]
M.SET_KEYS = { "title", "status", "due", "includes", "close", "summary" }

---Longest slug of a new milestone.
M.MAX_SLUG = 80

---@class Tasks.Milestone
---@field id string
---@field area string
---@field slug string
---@field path string
---@field folder boolean
---@field title string
---@field status? string
---@field due? string
---@field reached? string
---@field close "auto"|"manual"
---@field includes string[]       # The ids as the file names them, each once, in file order.
---@field summary string
---@field created? string
---@field updated? string
---@field history string[]        # The lines of `## Verlauf` (without the leading `- `).
---@field errors string[]
---@field error_codes string[]
---@field valid boolean

---The lines of the history section of a body (`- ` items), without the dash.
---@param body string
---@return string[]
---@return string rest  # The body without that section (what the summary is read from).
local function history_of(body)
  local out, rest, inside = {}, {}, false
  local want = {}
  for _, h in ipairs(M.HISTORY) do
    want[h] = true
  end
  for line in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do
    local t = vim.trim(line)
    if t:match("^## ") then
      inside = want[t] == true
    end
    if inside then
      local item = t:match("^[-*] (.+)$")
      if item then
        out[#out + 1] = item
      end
    else
      rest[#rest + 1] = line
    end
  end
  return out, table.concat(rest, "\n")
end

---Read one milestone file's text. Always returns a milestone; a broken file carries `errors` (`valid = false`).
---@param text string
---@param ctx { path: string, area: string, slug?: string, folder?: boolean }
---@return Tasks.Milestone
function M.parse(text, ctx)
  local slug = ctx.slug or model.slug_of(ctx.path, "roadmap")
  local errors, codes = {}, {}
  local function bad(code, msg)
    errors[#errors + 1] = msg
    codes[#codes + 1] = code
  end
  ---@type Tasks.Milestone
  local m = {
    id = ctx.area .. "/" .. slug,
    area = ctx.area,
    slug = slug,
    path = fsio.norm(ctx.path),
    folder = ctx.folder == true,
    title = slug,
    close = "auto",
    includes = {},
    summary = "",
    history = {},
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
  elseif not parsed.has_block then
    bad("frontmatter-missing", "no frontmatter block")
  else
    local meta = parsed.meta
    m.title = model.field_text(meta.title, "title", bad) or slug
    if meta.title == nil then
      bad("title-missing", "title is missing")
    end
    local status = model.field_text(meta.status, "status", bad)
    if status then
      m.status = status
      if not vim.tbl_contains(M.STATUSES, status) then
        bad(
          "milestone-bad-status",
          ("unknown milestone status '%s' (expected %s)"):format(
            fsio.clean(status),
            table.concat(M.STATUSES, ", ")
          )
        )
      end
    else
      bad("milestone-bad-status", "status is missing")
    end
    for _, field in ipairs({ "due", "reached", "created", "updated" }) do
      local date = model.field_text(meta[field], field, bad)
      if date then
        if model.is_date(date) then
          m[field] = date
        else
          bad("bad-date", ("%s '%s' is not a date (YYYY-MM-DD)"):format(field, fsio.clean(date)))
        end
      end
    end
    local close = model.field_text(meta.close, "close", bad)
    if close then
      if vim.tbl_contains(M.CLOSE, close) then
        m.close = close --[[@as "auto"|"manual"]]
      else
        bad(
          "milestone-bad-close",
          ("close must be auto or manual, got '%s'"):format(fsio.clean(close))
        )
      end
    end
    local seen = {}
    for _, id in ipairs(model.field_list(meta.includes, "includes", bad)) do
      if not seen[id] then
        seen[id] = true
        m.includes[#m.includes + 1] = id
      end
    end
    if #m.includes > M.MAX_INCLUDES then
      bad(
        "milestone-too-many",
        ("includes names %d members (at most %d)"):format(#m.includes, M.MAX_INCLUDES)
      )
    end
    local history, rest = history_of(parsed.body or "")
    m.history = history
    -- the summary is never a line of the history
    m.summary = model.field_text(meta.summary, "summary", bad) or model.first_paragraph(rest)
  end
  m.valid = #errors == 0
  return m
end

---Read one milestone file from disk.
---@param path string
---@param ctx { area: string, slug?: string, folder?: boolean }
---@return Tasks.Milestone
function M.from_file(path, ctx)
  local text, err = fsio.read(path)
  local c = vim.tbl_extend("force", { path = path }, ctx)
  if not text then
    local m = M.parse("", c)
    m.errors = { "cannot read the file: " .. tostring(err) }
    m.error_codes = { "unreadable" }
    m.valid = false
    return m
  end
  return M.parse(text, c)
end

---The milestones of an area, by slug.
---@param area string
---@param opts? { root?: string }
---@return Tasks.Milestone[]|nil milestones
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
  local dir = vault.milestones_dir(root, area)
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

---Every milestone of the vault, areas in name order.
---@param opts? { root?: string }
---@return Tasks.Milestone[]|nil milestones
---@return string|nil err
function M.all(opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local out = {}
  for _, a in ipairs(vault.areas(root)) do
    vim.list_extend(out, M.area(a.name, { root = root }) or {})
  end
  return out, nil
end

---A milestone by id.
---@param id string
---@param opts? { root?: string }
---@return Tasks.Milestone|nil milestone
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
    return nil, "no such milestone: " .. id
  end
  if vault.leaves(root, vault.milestones_dir(root, area)) then
    return nil, "no such milestone: " .. id
  end
  local path, folder = vault.resolve_plan(root, "milestone", area, slug)
  if not path then
    return nil, (tostring(folder):gsub("no such open milestone", "no such milestone"))
  end
  return M.from_file(path, { area = area, slug = slug, folder = folder == true }), nil
end

-- ── members ──────────────────────────────────────────────────────────────────

---@class Tasks.MilestoneMember
---@field id string
---@field kind "task"|"plan"|"project"|"path"|"meeting"|"milestone"|"unknown"|"foreign"|"bad"
---@field state? "open"|"done"   # Only for a member of `M.KINDS`.
---@field title? string
---@field item? table              # The task, plan file, meeting or finished item.

---@class Tasks.MilestoneCache
---@field root string
---@field members table<string, Tasks.MilestoneMember>
---@field finished fun(id: string): boolean

---A cache for one pass over several milestones (a member is resolved once).
---@param root string
---@return Tasks.MilestoneCache
function M.cache(root)
  return {
    root = root,
    members = {},
    finished = require("tasks_nvim.scan").finished_lookup({ root = root }),
  }
end

---Whether `area` is an area of another configured vault (`setup({ vaults })`) and none of this one.
---@param root string
---@param area string
---@return boolean
local function area_of_other_vault(root, area)
  for _, name in ipairs(vault.vault_names()) do
    local other = vault.named_root(name)
    if other and not fsio.same_path(other, root) and vault.has_area(other, area) then
      return true
    end
  end
  return false
end

---What an id of `includes:` names: its kind, whether it is done, its title. An id written with a vault in front
---(`<vault>:<area>/<slug>`, `<vault>/<area>/<slug>`) or of an area that only another configured vault has is `foreign`;
---a malformed one `bad`; one that exists nowhere `unknown`.
---@param id string
---@param cache Tasks.MilestoneCache
---@return Tasks.MilestoneMember
function M.member(id, cache)
  local hit = cache.members[id]
  if hit then
    return hit
  end
  local root = cache.root
  local out
  local _, slashes = id:gsub("/", "")
  if id:find(":", 1, true) or slashes >= 2 then
    out = { id = id, kind = "foreign" }
  else
    local area, slug = vault.parse_id(id)
    if not area or not slug then
      out = { id = id, kind = "bad" }
    elseif not vault.has_area(root, area) then
      out = { id = id, kind = area_of_other_vault(root, area) and "foreign" or "unknown" }
    else
      local task = require("tasks_nvim.scan").find(id, { root = root })
      if task then
        out = { id = id, kind = "task", state = "open", title = task.title, item = task }
      end
      if not out then
        for _, kind in ipairs({ "plan", "project", "path" }) do
          if vault.resolve_plan(root, kind, area, slug) then
            local finder = (kind == "plan" and require("tasks_nvim.plans").find)
              or (kind == "project" and require("tasks_nvim.projects").find)
              or require("tasks_nvim.paths").find
            local f = finder(id, { root = root })
            out = {
              id = id,
              kind = kind,
              state = "open",
              title = f and f.title or slug,
              item = f,
            }
            break
          end
        end
      end
      if not out and vault.resolve_plan(root, "milestone", area, slug) then
        out = { id = id, kind = "milestone" }
      end
      if not out then
        local meeting = require("tasks_nvim.meetings").find_any(id, { root = root })
        if meeting then
          local closed = meeting.status == "done" or meeting.status == "cancelled"
          out = {
            id = id,
            kind = "meeting",
            state = closed and "done" or "open",
            title = meeting.title,
            item = meeting,
          }
        end
      end
      if not out and cache.finished(id) then
        local item = require("tasks_nvim.scan").find_done(id, { root = root })
        if item then
          out = {
            id = id,
            kind = require("tasks_nvim.projects").finished_kind(item),
            state = "done",
            title = item.title,
            item = item,
          }
        end
      end
      out = out or { id = id, kind = "unknown" }
    end
  end
  cache.members[id] = out
  return out
end

---Whether every member of a milestone is done. A milestone without members is never complete; a member that exists
---nowhere holds it open. The second value is the first member that is open (a member of a kind that is open, not one
---that is missing).
---@param m Tasks.Milestone
---@param cache Tasks.MilestoneCache
---@return boolean complete
---@return string|nil open_id
function M.complete(m, cache)
  local complete, open_id = #m.includes > 0, nil
  for _, id in ipairs(m.includes) do
    local member = M.member(id, cache)
    if member.state ~= "done" then
      complete = false
      if member.state == "open" and not open_id then
        open_id = id
      end
    end
  end
  return complete, open_id
end

---@class Tasks.MilestoneUnits
---@field done integer
---@field total integer

---@class Tasks.MilestoneCounts
---@field open Tasks.Task[]          # Every open task of the vault.
---@field plans Tasks.PlanFile[]     # Every open plan file.
---@field finished Tasks.Task[]      # Every finished item of the Backlogs.

---What the tasks of the vault and the Backlogs are, for the progress of plans and projects (read once per document).
---@param root string
---@return Tasks.MilestoneCounts
function M.counts(root)
  local scan = require("tasks_nvim.scan")
  local open = {}
  for _, a in ipairs(vault.areas(root)) do
    vim.list_extend(open, scan.area(a.name, { root = root }) or {})
  end
  return {
    open = open,
    plans = require("tasks_nvim.plans").all({ root = root }) or {},
    finished = require("tasks_nvim.projects").finished_items({ root = root }),
  }
end

---What one member adds to the progress: a plan or project counts its tasks (open and finished; one without any counts
---as one, done when it is closed), a task, a meeting and a path count one. A member that is no member counts nothing.
---@param member Tasks.MilestoneMember
---@param counts Tasks.MilestoneCounts
---@return Tasks.MilestoneUnits
function M.units(member, counts)
  if member.state == nil then
    return { done = 0, total = 0 }
  end
  local one = { done = member.state == "done" and 1 or 0, total = 1 }
  if member.kind == "plan" then
    local n_open, n_done = 0, 0
    for _, t in ipairs(counts.open) do
      if t.plan == member.id then
        n_open = n_open + 1
      end
    end
    local projects = require("tasks_nvim.projects")
    for _, item in ipairs(counts.finished) do
      if item.plan == member.id and projects.finished_kind(item) == "task" then
        n_done = n_done + 1
      end
    end
    if n_open + n_done == 0 then
      return one
    end
    return { done = n_done, total = n_open + n_done }
  elseif member.kind == "project" then
    local r = require("tasks_nvim.projects").rollup(
      { id = member.id } --[[@as Tasks.PlanFile]],
      { plans = counts.plans, open = counts.open, finished = counts.finished }
    )
    if r.tasks_open + r.tasks_done == 0 then
      return one
    end
    return { done = r.tasks_done, total = r.tasks_open + r.tasks_done }
  end
  return one
end

---@class Tasks.MilestoneProgress
---@field members integer        # Members named.
---@field members_done integer   # Members done.
---@field done integer           # Units done (`units`).
---@field total integer          # Units in all.
---@field complete boolean       # Every member is done (`complete`).

---The progress of a milestone.
---@param m Tasks.Milestone
---@param cache Tasks.MilestoneCache
---@param counts Tasks.MilestoneCounts
---@return Tasks.MilestoneProgress
function M.progress(m, cache, counts)
  local out = { members = #m.includes, members_done = 0, done = 0, total = 0 }
  for _, id in ipairs(m.includes) do
    local member = M.member(id, cache)
    if member.state == "done" then
      out.members_done = out.members_done + 1
    end
    local u = M.units(member, counts)
    out.done = out.done + u.done
    out.total = out.total + u.total
  end
  out.complete = M.complete(m, cache)
  return out
end

---@class Tasks.MilestoneOverlap
---@field id string     # The member named twice.
---@field via string    # The member it is already part of (a plan or project of the milestone).

---Members that are in the milestone twice: a task in a plan or project it names too, a plan or path in a project it
---names. Their progress would count twice.
---@param m Tasks.Milestone
---@param cache Tasks.MilestoneCache
---@return Tasks.MilestoneOverlap[]
function M.overlaps(m, cache)
  local named = {}
  for _, id in ipairs(m.includes) do
    named[id] = true
  end
  local out = {}
  local function project_of_plan(plan_id)
    local plan = M.member(plan_id, cache)
    return plan.item and plan.item.project or nil
  end
  for _, id in ipairs(m.includes) do
    local member = M.member(id, cache)
    local item = member.item
    local via
    if item and member.kind == "task" then
      local plan_project = item.plan and project_of_plan(item.plan) or nil
      via = (item.plan and named[item.plan] and item.plan)
        or (item.project and named[item.project] and item.project)
        or (plan_project and named[plan_project] and plan_project)
        or nil
    elseif item and (member.kind == "plan" or member.kind == "path") then
      via = item.project and named[item.project] and item.project or nil
    end
    if via then
      out[#out + 1] = { id = id, via = via }
    end
  end
  return out
end

-- ── writing ──────────────────────────────────────────────────────────────────

---A dated line for `## Verlauf`.
---@param day string
---@param what string
---@return string
local function history_line(day, what)
  return ("- %s %s"):format(day, what)
end

---The text of a milestone file with `pairs_` set in its frontmatter and `lines` added to `## Verlauf`.
---@param text string
---@param pairs_ table[]
---@param lines string[]
---@return string|nil text
---@return string|nil err
local function rewrite(text, pairs_, lines)
  local out, err = fm.update_text(text, pairs_)
  if not out then
    return nil, err
  end
  if #lines > 0 then
    local mw = require("tasks_nvim.meeting_write")
    local head, body = mw.split_file(out)
    if not head then
      return nil, "the milestone has no frontmatter block"
    end
    out = head .. mw.append_to_section(body or "", M.HISTORY, lines)
  end
  return out, nil
end

---@class Tasks.MilestoneSettle
---@field reached string[]   # Milestones this pass reached.
---@field reopened string[]  # Milestones this pass set back to `doing`.
---@field notes string[]     # Milestones that could not be written.

---Bring every milestone of the vault in line with its members: one of `close: auto` (not `parked`) whose members are
---all done is reached (`status: done`, `reached: <today>`, a line in `## Verlauf`); a reached one (`status: done`)
---with a member open again goes back to `doing` (its `reached` stays, a line says why). Each file is judged again
---under its lock. Called after every write that can finish or open a member (`done_flow`, `ops`).
---@param opts? { root?: string, today?: string, dry_run?: boolean }
---@return Tasks.MilestoneSettle
function M.settle(opts)
  opts = opts or {}
  local out = { reached = {}, reopened = {}, notes = {} }
  local root = vault.root(opts)
  if not root then
    return out
  end
  local today = opts.today or model.today()
  local cache
  for _, a in ipairs(vault.areas(root)) do
    if fsio.is_dir(vault.milestones_dir(root, a.name)) then
      for _, m in ipairs(M.area(a.name, { root = root }) or {}) do
        if m.valid and m.status ~= "parked" and #m.includes > 0 then
          cache = cache or M.cache(root)
          local complete, open_id = M.complete(m, cache)
          local action
          if m.status == "done" and open_id then
            action = "reopen"
          elseif m.status ~= "done" and complete and m.close == "auto" then
            action = "reach"
          end
          if action and not opts.dry_run then
            local ok, werr = fsio.with_lock(m.path, function()
              local cur = fsio.read(m.path)
              if not cur then
                return nil, "cannot read " .. m.id
              end
              local now = M.parse(cur, { path = m.path, area = m.area, slug = m.slug })
              -- changed since it was read: judged on the next write
              if now.status ~= m.status then
                return true
              end
              local pairs_, lines
              if action == "reach" then
                pairs_ = { { "status", "done" }, { "reached", today }, { "updated", today } }
                lines = { history_line(today, "reached") }
              else
                pairs_ = { { "status", "doing" }, { "updated", today } }
                lines = {
                  history_line(today, ("opened again: %s is open"):format(tostring(open_id))),
                }
              end
              local text, rerr = rewrite(cur, pairs_, lines)
              if not text then
                return nil, rerr
              end
              return fsio.write_atomic(m.path, text)
            end)
            if ok then
              table.insert(action == "reach" and out.reached or out.reopened, m.id)
            else
              out.notes[#out.notes + 1] = ("milestone %s was not updated: %s"):format(
                m.id,
                tostring(werr)
              )
            end
          elseif action then
            table.insert(action == "reach" and out.reached or out.reopened, m.id)
          end
        end
      end
    end
  end
  return out
end

---Judge a list of member ids for writing: each must be an id of this vault that names a task, plan, project, path or
---meeting (a milestone in a milestone, an id of another vault, one that exists nowhere are refused). Each once.
---@param value any
---@param root string
---@return string[]|nil ids
---@return string|nil err
---@return table|nil details
function M.judge_includes(value, root)
  local items = type(value) == "table" and value
    or vim.split(tostring(value or ""), ",", { plain = true })
  local out, seen, problems = {}, {}, {}
  local cache = M.cache(root)
  for _, item in ipairs(items) do
    if type(item) ~= "string" then
      return nil, "includes must be a list of ids"
    end
    local id = vim.trim(item)
    if id:find("[,%[%]\"'#\r\n]") then
      return nil, "includes item '" .. id .. "' must not contain , [ ] quotes # or a line break"
    end
    if id ~= "" and not seen[id] then
      seen[id] = true
      local member = M.member(id, cache)
      if member.kind == "foreign" then
        problems[#problems + 1] = {
          code = "milestone-include-foreign",
          target = id,
          message = id .. " is an id of another vault: a milestone names ids of its own vault",
        }
      elseif member.kind == "bad" then
        problems[#problems + 1] =
          { code = "milestone-bad-include", target = id, message = id .. " is no <area>/<slug>" }
      elseif member.kind == "milestone" then
        problems[#problems + 1] = {
          code = "milestone-nested",
          target = id,
          message = id .. " is a milestone: a milestone does not include another one",
        }
      elseif member.kind == "unknown" then
        problems[#problems + 1] = {
          code = "milestone-include-unknown",
          target = id,
          message = id .. " exists nowhere (no task, plan, project, path or meeting)",
        }
      end
      out[#out + 1] = id
    end
  end
  if #out > M.MAX_INCLUDES then
    return nil, ("includes names %d members (at most %d)"):format(#out, M.MAX_INCLUDES)
  end
  if #problems > 0 then
    return nil, problems[1].message, { problems = problems }
  end
  return out, nil
end

---One line of text, or an error.
---@param value any
---@param what string
---@return string|nil
---@return string|nil err
local function one_line(value, what)
  if type(value) ~= "string" then
    return nil, what .. " must be a text"
  end
  local t = vim.trim(fsio.clean(value))
  if t:find("[\r\n]") then
    return nil, what .. " must be one line"
  end
  return t, nil
end

---Make a milestone file. `opts.status` is `planning`, `doing` (the default) or `parked`; `includes` are judged as
---`judge_includes` does; `due` is a day. A dry run names the id it would get.
---@param area string
---@param opts { root?: string, today?: string, title: string, due?: string, includes?: string[]|string, close?: string, status?: string, summary?: string, slug?: string, dry_run?: boolean }
---@return { id: string, path: string, slug: string, renamed: boolean }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "invalid_argument", details? }`
function M.new(area, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local invalid = function(msg, details)
    return nil, msg, { code = "invalid_argument", details = details }
  end
  if not vault.has_area(root, area) then
    return invalid("unknown area: " .. tostring(area))
  end
  local title, terr = one_line(opts.title, "title")
  if not title or title == "" then
    return invalid(terr or "title must be one non-empty line")
  end
  local status = opts.status or "doing"
  if not vim.tbl_contains(M.STATUSES, status) or status == "done" then
    return invalid(
      ("unknown milestone status '%s' (expected planning, doing or parked)"):format(
        tostring(status)
      )
    )
  end
  if opts.due ~= nil and not model.is_date(opts.due) then
    return invalid("due is not a date (YYYY-MM-DD): " .. tostring(opts.due))
  end
  if opts.close ~= nil and not vim.tbl_contains(M.CLOSE, opts.close) then
    return invalid("close must be auto or manual, got '" .. tostring(opts.close) .. "'")
  end
  local includes = {}
  if opts.includes ~= nil then
    local ids, ierr, details = M.judge_includes(opts.includes, root)
    if not ids then
      return invalid(tostring(ierr), details)
    end
    includes = ids
  end
  local summary
  if opts.summary ~= nil then
    local serr
    summary, serr = one_line(opts.summary, "summary")
    if not summary then
      return invalid(tostring(serr))
    end
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD): " .. tostring(today)
  end
  local base = opts.slug or require("tasks_nvim.mutate").slugify(title)
  local slug_err, slug_details = vault.slug_error("slug", base)
  if slug_err then
    return invalid(slug_err, slug_details)
  end
  if vault.is_reserved_name(base) then
    return invalid(("slug '%s' is a reserved Windows device name"):format(base))
  end
  if #base > M.MAX_SLUG then
    return invalid(("slug is longer than %d characters"):format(M.MAX_SLUG))
  end
  local pairs_ = { { "title", title }, { "status", status } }
  if opts.due then
    pairs_[#pairs_ + 1] = { "due", opts.due }
  end
  pairs_[#pairs_ + 1] = { "includes", includes }
  if opts.close == "manual" then
    pairs_[#pairs_ + 1] = { "close", "manual" }
  end
  if summary and summary ~= "" then
    pairs_[#pairs_ + 1] = { "summary", summary }
  end
  pairs_[#pairs_ + 1] = { "created", today }
  pairs_[#pairs_ + 1] = { "updated", today }
  local body = table.concat({
    "",
    "## Ziel",
    "",
    "<!-- Woran man merkt, dass der Meilenstein erreicht ist. -->",
    "",
    M.HISTORY[1],
    "",
  }, "\n")
  local text, ferr = fm.update_text(body, pairs_, { create = true })
  if not text then
    return nil, "cannot build the milestone file: " .. tostring(ferr)
  end
  local dir = vault.milestones_dir(root, area)
  if not opts.dry_run then
    local ok, mkerr = fsio.mkdirp(dir)
    if not ok then
      return nil, "cannot create " .. dir .. ": " .. tostring(mkerr)
    end
  end
  local backlog_taken, berr = require("tasks_nvim.scan").backlog_slugs(area, { root = root })
  if not backlog_taken then
    return nil, berr
  end
  for n = 1, 999 do
    local slug = n == 1 and base or (base .. "-" .. n)
    local path = dir .. "/" .. slug .. ".md"
    -- one id namespace: tasks, plans, projects, paths, meetings and milestones
    local held = backlog_taken[slug] ~= nil
      or fsio.is_file(vault.task_path(root, area, slug))
      or fsio.is_dir(vault.task_dir(root, area, slug))
      or vault.has_plan_or_project(root, area, slug)
      or fsio.is_dir(dir .. "/" .. slug)
    if not held and opts.dry_run then
      return { id = area .. "/" .. slug, path = path, slug = slug, renamed = n > 1 }, nil
    end
    if not held then
      local ok, err = fsio.create_exclusive(path, text)
      if ok then
        return { id = area .. "/" .. slug, path = path, slug = slug, renamed = n > 1 }, nil
      end
      if not fsio.is_exists(err) then
        return nil, "cannot create " .. path .. ": " .. tostring(err)
      end
    end
  end
  return nil, "no free file name for milestone " .. base
end

---Change the frontmatter of a milestone (`SET_KEYS`); `nil`, `vim.NIL`, an empty text or list removes a key (not
---`title` and `status`). `status: done` reaches it by hand: refused while a member is not done (`details.holding`),
---else `reached` is today and `## Verlauf` gets a line. `reached` is the engine's; it is never set here.
---@param id string
---@param patch table<string, any>
---@param opts? { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return { id: string, path: string, etag_before: string, etag_after: string, changed: boolean, before: table<string, any> }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict", details? }`
function M.set(id, patch, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local m, ferr = M.find(id, { root = root })
  if not m then
    return nil, ferr, { code = "not_found" }
  end
  local invalid = function(msg, details)
    return nil, msg, { code = "invalid_argument", details = details }
  end
  local keys = vim.tbl_keys(patch)
  table.sort(keys)
  if #keys == 0 then
    return invalid("the patch is empty")
  end
  local today = opts.today or model.today()
  local pairs_, reach = {}, false
  for _, key in ipairs(keys) do
    if not vim.tbl_contains(M.SET_KEYS, key) then
      return invalid(
        ("unknown field '%s' (settable: %s)"):format(tostring(key), table.concat(M.SET_KEYS, ", "))
      )
    end
    local value = patch[key]
    local remove = value == nil
      or value == vim.NIL
      or value == ""
      or (type(value) == "table" and #value == 0)
    if remove then
      if key == "title" or key == "status" then
        return invalid(key .. " cannot be removed")
      end
      pairs_[#pairs_ + 1] = { key, key == "includes" and {} or fm.REMOVE }
    elseif key == "includes" then
      local ids, ierr, details = M.judge_includes(value, root)
      if not ids then
        return invalid(tostring(ierr), details)
      end
      pairs_[#pairs_ + 1] = { key, ids }
    else
      local text, terr = one_line(value, key)
      if not text then
        return invalid(tostring(terr))
      end
      if key == "status" and not vim.tbl_contains(M.STATUSES, text) then
        return invalid(
          ("unknown milestone status '%s' (expected %s)"):format(
            text,
            table.concat(M.STATUSES, ", ")
          )
        )
      elseif key == "due" and not model.is_date(text) then
        return invalid("due is not a date (YYYY-MM-DD): " .. text)
      elseif key == "close" and not vim.tbl_contains(M.CLOSE, text) then
        return invalid("close must be auto or manual, got '" .. text .. "'")
      end
      if key == "status" and text == "done" and m.status ~= "done" then
        reach = true
      end
      pairs_[#pairs_ + 1] = { key, text }
    end
  end
  if reach then
    -- judged with the members as they would be afterwards
    local after = vim.deepcopy(m)
    for _, kv in ipairs(pairs_) do
      if kv[1] == "includes" then
        after.includes = kv[2]
      end
    end
    local cache = M.cache(root)
    if #after.includes == 0 then
      return invalid(m.id .. " names no members: nothing to reach")
    end
    local holding = {}
    for _, mid in ipairs(after.includes) do
      if M.member(mid, cache).state ~= "done" then
        holding[#holding + 1] = mid
      end
    end
    if #holding > 0 then
      return invalid(
        ("%s still has %d member%s that %s not done"):format(
          m.id,
          #holding,
          #holding == 1 and "" or "s",
          #holding == 1 and "is" or "are"
        ),
        { holding = holding }
      )
    end
    pairs_[#pairs_ + 1] = { "reached", today }
  end
  local result = { id = m.id, path = m.path }
  local ok, werr, winfo = fsio.with_lock(m.path, function()
    local cur, rd_err = fsio.read(m.path)
    if not cur then
      return nil, "cannot read " .. m.id .. ": " .. tostring(rd_err)
    end
    local etag = fsio.etag(cur)
    result.etag_before = etag
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on (it is %s, the change was made on %s)"):format(
          m.id,
          etag,
          tostring(opts.if_match)
        ),
        { code = "conflict", id = m.id, expected = opts.if_match, actual = etag }
    end
    local parsed = fm.parse(cur)
    local before = {}
    for _, kv in ipairs(pairs_) do
      if kv[1] ~= "reached" then
        local old = parsed and parsed.has_block and fm.get(parsed, kv[1]) or nil
        before[kv[1]] = old == nil and vim.NIL or old
      end
    end
    result.before = before
    local text, uerr =
      rewrite(cur, pairs_, reach and { history_line(today, "reached (closed by hand)") } or {})
    if not text then
      return nil, "cannot change " .. m.id .. ": " .. tostring(uerr), { code = "invalid_argument" }
    end
    if text ~= cur then
      text = fm.update_text(text, { { "updated", today } }) or text
    end
    result.etag_after = fsio.etag(text)
    result.changed = text ~= cur
    if opts.dry_run or not result.changed then
      return true
    end
    local wrote, wr_err = fsio.write_atomic(m.path, text)
    if not wrote then
      return nil, "cannot write " .. m.id .. ": " .. tostring(wr_err)
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  return result, nil
end

return M
