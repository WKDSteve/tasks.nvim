---@module 'tasks_nvim.ui.cmd'
---@brief The handlers behind `:Tasks list | task | open` -- prompts, notifications and windows around the task engine.
---@description
--- Every function takes the composer's `ctx` (`ctx.args`, `ctx.flags`,
--- `ctx.kv`, `ctx.rest`, `ctx.raw.fargs`) and does one command. The engine
--- (`tasks.*`) holds all the rules and returns data or `nil, err`; this module
--- adds what an editor needs: the `--to=` delivery, a form for a missing
--- title, a confirmation before a task is finished, opening files and
--- re-pointing buffers, and a picker over the files of one area folder.
---
--- Key responsibilities:
---  - `list` (`tasks`), `index`, `task_new`, `task_set`, `task_done`,
---    `task_template`, `task_open`, `task_preview`, `open_area` (`open`)
---  - `parse_assignments`: `key=value` tokens whose values may contain spaces
---  - `M.dashboard`: the seam to the interactive dashboard (`tasks_dash`)
---
--- Not its job: the route table and the argument types (`tasks_routes`), the
--- rendering (`tasks_view`), any rule about tasks (the engine).

local harvest = require("lib.nvim.harvest")
local notify = require("lib.nvim.notify").create("[tasks]")

local check = require("tasks_nvim.check")
local claims = require("tasks_nvim.claims")
local filter_opts = require("tasks_nvim.filter_opts")
local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local questions = require("tasks_nvim.questions")
local scan = require("tasks_nvim.scan")
local staleness = require("tasks_nvim.staleness")
local vault = require("tasks_nvim.vault")

local confirm = require("tasks_nvim.ui.confirm")
local done_flow = require("tasks_nvim.done_flow")
local soft = require("tasks_nvim.soft")
local view = require("tasks_nvim.ui.view")

local M = {}

---Before a write through the door (`ops.run`): the head of its answer names the engine's commit, which git is asked for
---in the background (`contract.prewarm`), so the editor never waits for it.
local function write_door_prewarm()
  require("tasks_nvim.contract").prewarm()
end

---Dashboard seam. `:Tasks list` calls it instead of delivering a table
---when neither `--to=` nor `--format=` was given. It receives the filtered,
---sorted open tasks; with `--stale=refs` a replaced hook is called once the
---background refs check answered (the built-in dashboard checks on its own). `nil` (the default) means the interactive dashboard
---(`tasks_dash`); assign a function to replace it, or `false` for the old
---behaviour, a scratch buffer.
---@type (fun(view: Tasks.View): any)|false|nil
M.dashboard = nil

---@class Tasks.View
---@field tasks Tasks.Task[]     # Open tasks that passed the filter, sorted.
---@field area string|nil        # nil: every area.
---@field filter Tasks.Filter
---@field sort? string           # `model.SORTS` word the list was ordered by (default: the default order).
---@field root string          # Vault root.

---Longest detail list put into a notification; longer ones open a buffer.
local MAX_NOTIFY_LINES = 10

---The subfolders of an area `:Tasks folder` can show, relative to the area.
---@type table<string, string>
M.FOLDERS = {
  tasks = "ROADMAP/tasks",
  roadmap = "ROADMAP",
  backlog = "Backlog",
  handover = "handovers",
  notes = "NOTES",
  all = "",
}

-- ── helpers ──────────────────────────────────────────────────────────────────

local same_path = fsio.same_path

---An existing `file:` target is replaced only after a yes in a dialog (UI-05): the command already knows the file,
---so it asks instead of telling the user to type the whole line again with `--force`. `--force` skips the question.
---`run(force)` is called at once when nothing is in the way, after a yes with `true`; a no leaves the file alone.
---@param target Tasks.Target|nil
---@param force boolean|nil
---@param run fun(force: boolean|nil)
local function unless_overwrite_refused(target, force, run)
  local blocked = view.overwrite_guard(target, force)
  if not blocked then
    run(force)
    return
  end
  confirm.yesno(blocked .. ". Overwrite it?", "overwrite", function(yes)
    if yes then
      run(true)
    else
      notify.info("cancelled -- the file stays as it is")
    end
  end)
end

---@param path string
---@param root string
---@return string
local function rel(path, root)
  local p = fsio.norm(path)
  if p:sub(1, #root + 1) == root .. "/" then
    return p:sub(#root + 2)
  end
  return p
end

---Notify a summary; the detail lines go along when few, into a scratch buffer
---when many.
---@param level "info"|"warn"|"error"
---@param summary string
---@param details? string[]
---@param title? string
local function report(level, summary, details, title)
  details = details or {}
  if #details == 0 then
    notify[level](summary)
  elseif #details <= MAX_NOTIFY_LINES then
    notify[level](summary .. "\n" .. table.concat(details, "\n"))
  else
    harvest.sink.scratch(table.concat(details, "\n") .. "\n", {
      title = title,
      filetype = "text",
      split = "split",
    })
    notify[level](summary)
  end
end

---@return string|nil root
local function vault_root()
  local root, err = vault.root()
  if not root then
    notify.error(tostring(err))
    return nil
  end
  return root
end

---Strip one pair of surrounding double quotes: the command line does not
---interpret them, so `"Fix the thing"` arrives as three tokens with quotes on
---the outer two.
---@param s string
---@return string
local function unquote(s)
  s = vim.trim(s)
  local inner = s:match('^"(.*)"$')
  return inner and vim.trim(inner) or s
end

---`--list=<name>`: the named list's options under the ones typed (a flag you gave wins), its area when no area was
---typed. Reports the problem and returns false when the list is unknown or broken, names an area the vault does not
---have, or sets something this command has no use for (`unsupported`: those flag words; a list that sets one is an
---error, never quietly cut short -- only `sort` is left over, it orders and does not select).
---@param ctx table  composer context
---@param unsupported? string[]
---@return boolean ok
local function apply_list(ctx, unsupported)
  local name = ctx.flags and ctx.flags.list
  if name == nil then
    return true
  end
  local lists = require("tasks_nvim.lists")
  local entry, err = lists.get(name)
  if not entry then
    notify.error(tostring(err))
    return false
  end
  local resolved, rerr = lists.resolve(entry.def)
  if not resolved then
    notify.error(tostring(rerr))
    return false
  end
  local area = entry.def.area
  if area then
    local root = vault_root()
    if not root then
      return false
    end
    -- a list may name an area group: it filters like an area
    local _, aerr = vault.area_scope(root, area)
    if aerr then
      notify.error(("list '%s': %s"):format(name, aerr))
      return false
    end
  end
  local function refuses(flag)
    return vim.tbl_contains(unsupported or {}, flag)
  end
  for key, value in pairs(entry.def) do
    local flag = key == "readiness" and value or key:gsub("_", "-")
    if refuses(flag) then
      notify.error(("list '%s' sets %s, which this command does not take"):format(name, flag))
      return false
    end
  end
  ctx.flags.list = nil
  for key, value in pairs(entry.def) do
    if key == "readiness" then
      if ctx.flags.ready == nil and ctx.flags.waiting == nil then
        ctx.flags[value] = true
      end
    elseif key == "area" then
      ctx.args = ctx.args or {}
      if ctx.args.area == nil then
        ctx.args.area = value
      end
    elseif key == "stale_refs" then
      if ctx.flags.stale == nil then
        ctx.flags.stale = "refs"
      end
    elseif key ~= "desc" then
      local flag = key:gsub("_", "-")
      if ctx.flags[flag] == nil then
        ctx.flags[flag] = value
      end
    end
  end
  return true
end

---Refuse words a command has no use for. Ignoring them is the worse outcome: the command line
---splits at spaces, so `--to=file:C:/my dir/x.md` arrives as `--to=file:C:/my` plus the stray
---`dir/x.md`, and the export would be written to a file called `my`.
---@param ctx table  composer context
---@return boolean ok  # false: the error is reported, the command must stop
local function no_stray_words(ctx)
  local rest = ctx.rest
  if rest == nil or #rest == 0 then
    return true
  end
  local to = ctx.flags and ctx.flags.to
  local hint = ""
  if type(to) == "string" and to:sub(1, 5) == "file:" then
    hint = " (put a backslash before each space of the --to=file: path)"
  end
  notify.error("unexpected argument: " .. table.concat(rest, " ") .. hint)
  return false
end

---Reload unchanged buffers of `path` after the file changed on disk.
---@param path string
local function refresh_buffers(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and not vim.bo[buf].modified
      and same_path(vim.api.nvim_buf_get_name(buf), path)
    then
      pcall(vim.cmd, "checktime " .. buf)
    end
  end
end

M.refresh_buffers = refresh_buffers

---Move windows showing `from` to `to` after a task file was moved, and drop
---the old buffer, so no buffer is left on a dead path (what `:File move` of
---fileops.nvim does for its own moves). A modified buffer is left alone.
---@param from string
---@param to string
function M.retarget_buffers(from, to)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and same_path(vim.api.nvim_buf_get_name(buf), from) then
      if vim.bo[buf].modified then
        notify.warn("buffer for the finished task has unsaved changes and still points at " .. from)
      else
        -- `edit` can refuse (a window with 'winfixbuf': E1513). The task is already finished on disk by now,
        -- so a refusal must not raise out of the command and eat its own report: it is collected and said.
        local refused = 0
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          local moved = pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("silent keepalt edit " .. vim.fn.fnameescape(to))
          end)
          if not moved then
            refused = refused + 1
          end
        end
        if refused > 0 then
          notify.warn(
            ("%d window(s) could not be moved to %s and still show the old file (it moved)"):format(
              refused,
              to
            )
          )
        else
          pcall(vim.api.nvim_buf_delete, buf, {})
        end
      end
    end
  end
end

---@param path string
local function open_file(path)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    notify.error(("cannot open %s: %s"):format(path, tostring(err)))
  end
end
M.open_file = open_file

---Describe the active filter for the table heading.
---@param flags table
---@return string|nil
local function filter_note(flags)
  local parts = {}
  for _, name in ipairs({
    "status",
    "prio",
    "effort",
    "kind",
    "category",
    "severity",
    "waits-for",
    "value",
    "actor",
    "tag",
    "sheet",
    "claimed",
  }) do
    if flags[name] ~= nil then
      parts[#parts + 1] = ("%s=%s"):format(name, flags[name])
    end
  end
  -- plan and phase come as lists (a comma list on the line)
  for _, name in ipairs({ "plan", "project", "phase" }) do
    local v = flags[name]
    if v ~= nil then
      parts[#parts + 1] = ("%s=%s"):format(
        name,
        type(v) == "table" and table.concat(v, ",") or tostring(v)
      )
    end
  end
  if flags.stale == "refs" then
    parts[#parts + 1] = "stale=refs"
  elseif flags.stale ~= nil then
    parts[#parts + 1] = "stale>=" .. tostring(flags.stale) .. "d"
  end
  if flags.blocked then
    parts[#parts + 1] = "blocked"
  end
  for _, name in ipairs({ "ready", "waiting", "reminders", "overdue", "unestimated", "quick-win" }) do
    if flags[name] then
      parts[#parts + 1] = name
    end
  end
  if #parts == 0 then
    return nil
  end
  return "Filter: " .. table.concat(parts, ", ")
end
M.filter_note = filter_note

-- ── tasks ────────────────────────────────────────────────────────────────────

---The filter flags the list-like commands share, as `filter_opts` wants them.
---@param flags table
---@return table
local function filter_options(flags)
  return {
    status = flags.status,
    prio = flags.prio,
    effort = flags.effort,
    kind = flags.kind,
    category = flags.category,
    severity = flags.severity,
    waits_for = flags["waits-for"],
    value = flags.value,
    actor = flags.actor,
    tag = flags.tag,
    stale = flags.stale,
    blocked = flags.blocked,
    unestimated = flags.unestimated,
    quick_win = flags["quick-win"],
    plan = flags.plan,
    project = flags.project,
    phase = flags.phase,
  }
end

---`--stale=refs` commands (`list`, `plan`, `estimate`, `quickwins`) waiting for their background check.
local ref_checks = 0

---The background checks of `load_scope` by command name: a newer `:Tasks plan` cancels the check of the older one,
---whose late answer then delivers nothing.
---@type table<string, { job: Tasks.StalenessJob|nil }>
local scope_checks = {}

---The scope of `plan`, `estimate` and `quickwins` from the command: area (or `all`), `--for=<id>`, the filters.
---`--stale=refs` never makes the editor wait for git: every other criterion first, the refs of what is left in the
---background (`staleness.compute_async`), then the scope again with the dated refs. `cb(scope)` runs once the scope
---is known (at once without `--stale=refs`); an error is told and `cb` is not called.
---@param ctx table
---@param name string  # the command: a newer one of the same name cancels the background check of the older one
---@param cb fun(scope: Tasks.PlanScope)
local function load_scope(ctx, name, cb)
  local flags = ctx.flags
  local filter, ferr = filter_opts.parse(filter_options(flags))
  if not filter then
    notify.error(tostring(ferr))
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  filter.ref_opts = { root = root }
  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local plan_scope = require("tasks_nvim.plan_scope")
  local opts = {
    root = root,
    area = area,
    for_id = flags["for"],
    plan_id = flags.plan,
    project_id = (type(flags.project) == "string" and not flags.project:find(",", 1, true))
        and flags.project
      or nil,
    filter = filter,
  }
  ---@param scope Tasks.PlanScope|nil
  ---@param err string|nil
  local function finish(scope, err)
    if not scope then
      notify.error(tostring(err))
      return
    end
    if #scope.errors > 0 then
      notify.warn("cannot read directory " .. table.concat(scope.errors, ", "))
    end
    cb(scope)
  end

  local older = scope_checks[name]
  if older then
    scope_checks[name] = nil
    ref_checks = ref_checks - 1
    if older.job then
      older.job.cancel()
    end
  end
  if not filter.stale_refs then
    finish(plan_scope.load(opts))
    return
  end
  -- one pass over the vault for both loads: the refs are dated for exactly the tasks the second load filters
  local shared, serr = plan_scope.shared(root)
  if not shared then
    finish(nil, serr)
    return
  end
  local rest = vim.tbl_extend("force", {}, filter)
  rest.stale_refs, rest.ref_stale = nil, nil
  local pre, perr = plan_scope.load(vim.tbl_extend("force", opts, { filter = rest }), shared)
  if not pre then
    finish(nil, perr)
    return
  end
  notify.info(
    ("--stale=refs: checking the refs of %d task(s) in the background ..."):format(#pre.tasks)
  )
  local pending = {}
  scope_checks[name] = pending
  ref_checks = ref_checks + 1
  pending.job = staleness.compute_async(pre.tasks, filter.ref_opts, function(rep)
    if scope_checks[name] ~= pending then
      return
    end
    scope_checks[name] = nil
    ref_checks = ref_checks - 1
    for _, n in ipairs(rep.notes) do
      notify.warn(n)
    end
    filter.ref_stale = rep.stale
    finish(plan_scope.load(opts, shared))
  end)
end

---`:Tasks plan [<area>|all] [--for=<id>] [filters] [--ready] [--format=md|tsv|ids] [--to=] [--force]`
---@param ctx table  composer context
function M.plan(ctx)
  if not no_stray_words(ctx) then
    return
  end
  if not apply_list(ctx, { "waiting", "reminders", "overdue" }) then
    return
  end
  local flags = ctx.flags
  local target, terr = view.parse_target(flags.to)
  if terr then
    notify.error(terr)
    return
  end
  local format = flags.format or "md"
  if format ~= "md" and format ~= "tsv" and format ~= "ids" then
    notify.error("--format must be md, tsv or ids")
    return
  end
  load_scope(ctx, "plan", function(scope)
    local plan_view = require("tasks_nvim.plan_view")
    if flags.write then
      return M.write_plan_block(ctx, scope)
    end
    if flags.check then
      notify.error("--check goes with --write=<file>")
      return
    end
    local text
    if format == "md" then
      text = plan_view.markdown(scope.plan, {
        title = scope.title,
        today = model.today(),
        done = scope.done,
        ready_only = flags.ready == true,
        with_steps = flags["with-steps"] == true,
        plan_file = scope.plan_file,
      })
    elseif format == "tsv" then
      text = table.concat(plan_view.tsv(scope.plan, { ready_only = flags.ready == true }), "\n")
        .. "\n"
    else
      text = table.concat(plan_view.ids(scope.plan, { ready_only = flags.ready == true }), "\n")
        .. "\n"
    end
    unless_overwrite_refused(target, flags.force, function(force)
      local ok, err = view.deliver_text(text, target, {
        force = force,
        title = "tasks/plan/" .. scope.title:gsub("[^%w._-]+", "-"),
        filetype = format == "md" and "markdown" or "text",
      })
      if not ok then
        notify.error(tostring(err))
        return
      end
      notify.info(
        ("plan of %s: %d task(s), %d ready"):format(scope.title, #scope.tasks, #scope.plan.ready)
      )
    end)
  end)
end

---`:Tasks lists`: pick a named list and open it as the dashboard.
---@param ctx table  composer context
function M.lists(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local lists = require("tasks_nvim.lists")
  local entries, notes = lists.all()
  for _, n in ipairs(notes) do
    notify.warn(n)
  end
  vim.ui.select(entries, {
    prompt = "Task list",
    format_item = function(e)
      return ("%s  [%s]  %s"):format(e.name, e.source, lists.summary(e.def))
    end,
  }, function(entry)
    if not entry then
      return
    end
    M.list({ args = {}, flags = { list = entry.name }, rest = {} })
  end)
end

---`:Tasks quickwins [<area>|all] [filters] [--to=] [--format=md|tsv|ids] [--by-actor] [--paths] [--report=<file>]`:
---the quick wins (value and effort at the thresholds of `setup({ quick_wins })`), best return first, with the small
---tasks that still miss a value. Default status: what can be picked up (open, doing, decision).
---@param ctx table  composer context
function M.quickwins(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local flags = ctx.flags
  local target, terr = view.parse_target(flags.to)
  if terr then
    notify.error(terr)
    return
  end
  local format = flags.format or "md"
  if format ~= "md" and format ~= "tsv" and format ~= "ids" then
    notify.error("--format must be md, tsv or ids")
    return
  end
  if flags.status == nil and flags["waits-for"] == nil then
    -- `--waits-for` asks for parked tasks: the default would hide them
    flags.status = "open,doing,decision"
  end
  load_scope(ctx, "quickwins", function(scope)
    local qw = require("tasks_nvim.quick_wins")
    local result = qw.build(scope.tasks)
    local text_opts =
      { title = scope.title, by_actor = flags["by-actor"] == true, paths = flags.paths == true }
    if flags.report then
      local ok, where = qw.write(tostring(flags.report), qw.markdown(result, text_opts))
      if not ok then
        notify.error(where)
        return
      end
      notify.info(("quick wins: %d written to %s"):format(#result.wins, where))
      return
    end
    local text
    if format == "md" then
      text = qw.markdown(result, text_opts)
    elseif format == "tsv" then
      text = table.concat(qw.tsv(result), "\n") .. "\n"
    else
      text = table.concat(qw.ids(result), "\n") .. "\n"
    end
    unless_overwrite_refused(target, flags.force, function(force)
      local ok, err = view.deliver_text(text, target, {
        force = force,
        title = "tasks/quickwins/" .. scope.title:gsub("[^%w._-]+", "-"),
        filetype = format == "md" and "markdown" or "text",
      })
      if not ok then
        notify.error(tostring(err))
        return
      end
      notify.info(
        ("quick wins of %s: %d (of %d task(s))"):format(scope.title, #result.wins, result.n)
      )
    end)
  end)
end

---`:Tasks plan --write=<file> [--scope=<name>] [--check]`: replace only the generated block of the scope in a
---hand-written document; `--check` writes nothing and says whether it is out of date.
---@param ctx table
---@param scope Tasks.PlanScope
function M.write_plan_block(ctx, scope)
  local flags = ctx.flags
  local plan_view = require("tasks_nvim.plan_view")
  local path = fsio.doc_path(flags.write)
  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local key = flags.scope
    or plan_view.default_scope({ area = area, for_id = flags["for"], plan_id = flags.plan })
  -- The marker records how the block was made (target, view, filters): the refresh after a finish builds the same.
  local plan_scope = require("tasks_nvim.plan_scope")
  local attrs, aerr = plan_scope.marker_attrs(
    filter_options(flags),
    { ready = flags.ready == true, steps = flags["with-steps"] == true },
    { area = area, plan_id = flags.plan, for_id = flags["for"] },
    key
  )
  if not attrs then
    notify.error(tostring(aerr))
    return
  end
  local res, err =
    plan_scope.write_block(path, scope, { key = key, attrs = attrs, check = flags.check })
  if not res then
    notify.error(tostring(err))
    return
  end
  if res.state == "stale" then
    notify.warn(("the block `%s` in %s is out of date"):format(key, path))
  elseif res.state == "current" then
    notify.info(("the block `%s` in %s is current"):format(key, path))
  elseif res.state == "unchanged" then
    notify.info(("block `%s` in %s: unchanged"):format(key, path))
  else
    refresh_buffers(path)
    notify.info(("block `%s` in %s updated"):format(key, path))
  end
end

---`:Tasks planfile <area> <title...> [--areas=] [--phases=] [--gate=hard] [--target=] [--status=]`
---@param ctx table
function M.planfile(ctx)
  local flags = ctx.flags
  local title = unquote(table.concat(ctx.rest, " "))
  if title == "" then
    notify.error("a plan needs a title: :Tasks planfile <area> <title...>")
    return
  end
  local res, err = require("tasks_nvim.plans").new(ctx.args.area, {
    title = title,
    areas = flags.areas,
    phases = flags.phases,
    gate = flags.gate,
    target = flags.target,
    status = flags.status,
    icon = flags.icon,
    cover = flags.cover,
  })
  if not res then
    notify.error(tostring(err))
    return
  end
  notify.info(("created plan %s"):format(res.id))
  if res.ambiguous then
    notify.warn(require("tasks_nvim.wikilinks").ambiguity_message(res.ambiguous))
  end
  open_file(res.path)
end

---`:Tasks path-new <area> <title...>`: create a learning path (`paths.new`) and open it.
---@param ctx table
function M.path_new(ctx)
  local flags = ctx.flags
  local title = flags.title or unquote(table.concat(ctx.rest, " "))
  if title == "" then
    notify.error("a learning path needs a title: :Tasks path-new <area> <title...>")
    return
  end
  local res, err = require("tasks_nvim.paths").new(ctx.args.area, {
    title = title,
    areas = flags.areas,
    target = flags.target,
    project = flags.project,
    status = flags.status,
    summary = flags.summary,
    slug = flags.slug,
    web_links = flags.links,
    icon = flags.icon,
    cover = flags.cover,
    template = flags.template,
    tags = flags.tags,
    requires = flags.requires,
    requires_gate = flags["requires-gate"],
  })
  if not res then
    notify.error(tostring(err))
    return
  end
  notify.info(("created learning path %s"):format(res.id))
  if res.ambiguous then
    notify.warn(require("tasks_nvim.wikilinks").ambiguity_message(res.ambiguous))
  end
  open_file(res.path)
end

---Walk the tasks that miss an effort or a value and ask for them one by one; everything given is written in ONE
---batch at the end (an index write per area). `Skip` leaves a field out, `Stop` ends the walk and keeps what was given.
---@param tasks Tasks.Task[]
local function walk_estimates(tasks)
  local queue = {}
  for _, t in ipairs(tasks) do
    if t.value == nil or model.effort_days(t.effort) == nil then
      queue[#queue + 1] = t
    end
  end
  if #queue == 0 then
    notify.info("every task has an effort and a value")
    return
  end
  local ask = M.chooser or confirm.choose
  local steps = {}

  local function finish()
    if #steps == 0 then
      notify.info("estimate: nothing given, nothing changed")
      return
    end
    local res = require("tasks_nvim.batch").set_many(steps, {})
    local level, text = require("tasks_nvim.ui.dash_core").describe_set("estimate", res)
    notify[level](text)
  end

  local function visit(i)
    local t = queue[i]
    if not t then
      finish()
      return
    end
    local patch = {}
    local function done_task()
      if next(patch) then
        steps[#steps + 1] = { id = t.id, patch = patch }
      end
      visit(i + 1)
    end
    -- `Stop`, and a dialog that was dismissed (Esc, `q`): the walk ends HERE; what was given so far is kept and
    -- written, not dropped without a word.
    local function stop_here()
      if next(patch) then
        steps[#steps + 1] = { id = t.id, patch = patch }
      end
      finish()
    end
    local function ask_value()
      if t.value ~= nil then
        done_task()
        return
      end
      local msg = ("%s -- %s\n\nValue (1 = little, 5 = a lot)  [%d of %d]"):format(
        t.id,
        confirm.shorten(t.title, 60),
        i,
        #queue
      )
      ask(msg, { "Skip", "Stop", "1", "2", "3", "4", "5" }, function(pos)
        if pos == nil or pos == 2 then
          stop_here()
          return
        end
        if pos >= 3 then
          patch.value = tostring(pos - 2)
        end
        done_task()
      end)
    end
    if model.effort_days(t.effort) ~= nil then
      ask_value()
      return
    end
    local msg = ("%s -- %s\n\nEffort  [%d of %d]"):format(
      t.id,
      confirm.shorten(t.title, 60),
      i,
      #queue
    )
    ask(msg, { "Skip", "Stop", "XS", "S", "M", "L", "XL" }, function(pos)
      if pos == nil or pos == 2 then
        stop_here()
        return
      end
      if pos >= 3 then
        patch.effort = ({ "XS", "S", "M", "L", "XL" })[pos - 2]
      end
      ask_value()
    end)
  end
  visit(1)
end

---Replaces the dialog of `estimate --walk` (specs): `function(msg, choices, cb)`.
---@type (fun(msg: string, choices: string[], cb: fun(index: integer|nil)))|nil
M.chooser = nil

---`:Tasks estimate [<area>|all] [--for=<id>] [filters] [--walk]`
---@param ctx table  composer context
function M.estimate(ctx)
  if not no_stray_words(ctx) then
    return
  end
  if not apply_list(ctx, { "ready", "waiting", "reminders", "overdue" }) then
    return
  end
  load_scope(ctx, "estimate", function(scope)
    local estimate = require("tasks_nvim.estimate")
    local sums = estimate.rollup(scope.tasks, { done = scope.done })
    local lines = { scope.title .. ": " .. estimate.describe(sums) }
    if #sums.quick_wins > 0 then
      lines[#lines + 1] = "Quick wins: " .. table.concat(sums.quick_wins, ", ")
    end
    if #sums.unestimated > 0 then
      lines[#lines + 1] = ("%d task(s) miss an effort or a value (:Tasks estimate --walk goes through them)"):format(
        #sums.unestimated
      )
    end
    notify.info(table.concat(lines, "\n"))
    if ctx.flags.walk then
      walk_estimates(scope.tasks)
    end
  end)
end

---`:Tasks next [<area>|all] [--n=3] [--actor=]`
---@param ctx table  composer context
function M.next(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local flags = ctx.flags
  local count = 3
  if flags.n ~= nil then
    local n = tonumber(flags.n)
    if not n or n < 1 or n % 1 ~= 0 then
      notify.error("--n must be a whole number of at least 1, got " .. tostring(flags.n))
      return
    end
    count = n
  end
  if flags.actor and not (model.is_actor(flags.actor) or flags.actor == "none") then
    notify.error(
      "unknown actor in --actor: " .. tostring(flags.actor) .. " (expected cdx, me, pair or none)"
    )
    return
  end
  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local root = vault_root()
  if not root then
    return
  end
  local pick, err = require("tasks_nvim.next_pick").pick_from_vault({
    root = root,
    area = area,
    actor = flags.actor,
    n = count - 1,
  })
  if not pick then
    notify.error(tostring(err))
    return
  end
  if pick.incomplete then
    notify.warn(
      "cannot read directory "
        .. table.concat(pick.incomplete, ", ")
        .. " (the answer may be incomplete)"
    )
  end
  require("tasks_nvim.ui.next_popup").show(pick, nil)
end

---`:Tasks waits [<area>|all]`: what the parked tasks wait for -- per `waits_for` key the number of tasks and their
---areas, then the parked ones without a reason and the total.
---@param ctx table  composer context
function M.waits(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local open, skipped, errors = scan.open_tasks({ root = root, area = area })
  if not open then
    notify.error(tostring(skipped))
    return
  end
  local sum = require("tasks_nvim.waits").summary(open)
  local lines = {}
  for _, k in ipairs(sum.keys) do
    lines[#lines + 1] = ("%s: %d  (%s)"):format(k.key, k.count, table.concat(k.areas, ", "))
  end
  lines[#lines + 1] = ("parked without a reason: %d"):format(sum.without)
  if sum.invalid > 0 then
    lines[#lines + 1] = ("parked with an invalid waits_for: %d (see :Tasks index --check)"):format(
      sum.invalid
    )
  end
  lines[#lines + 1] = ("parked: %d"):format(sum.parked)
  if type(errors) == "table" and #errors > 0 then
    notify.warn("cannot read directory " .. table.concat(errors, ", "))
  end
  notify.info(table.concat(lines, "\n"))
end

---`:Tasks release <key> [--dry-run] [--yes]`: every parked task that waits for `<key>` goes back to `open` and loses
---the key (`batch.release`). It asks first, with the number of tasks; `--yes` skips the question, `--dry-run` only
---names the tasks.
---@param ctx table  composer context
---@param confirm_fn? fun(msg: string, label: string, cb: fun(yes: boolean))  A stand-in for the dialog (specs).
function M.release(ctx, confirm_fn)
  if not no_stray_words(ctx) then
    return
  end
  local key = ctx.args.key
  if not model.is_waits_for(key) then
    notify.error(model.waits_for_error(key))
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local batch = require("tasks_nvim.batch")
  local plan, perr = batch.release(key, { root = root, dry_run = true })
  if not plan then
    notify.error(tostring(perr))
    return
  end
  if #plan.incomplete > 0 then
    notify.warn("cannot read directory " .. table.concat(plan.incomplete, ", "))
  end
  if #plan.ids == 0 then
    notify.warn(("no parked task waits for '%s' (the keys in use: :Tasks waits)"):format(key))
    return
  end
  if ctx.flags["dry-run"] then
    notify.info(
      ("release %s would set %d task(s) to open:\n%s"):format(
        key,
        #plan.ids,
        table.concat(plan.ids, "\n")
      )
    )
    return
  end
  local function run()
    local res, err = batch.release(key, { root = root })
    if not res then
      notify.error(tostring(err))
      return
    end
    local done = res.result or { changed = {}, failed = {}, index_errors = {} }
    for _, changed in ipairs(done.changed) do
      refresh_buffers(changed.path)
    end
    for _, f in ipairs(done.failed) do
      notify.error(("%s: %s"):format(f.id, f.err))
    end
    for _, e in ipairs(done.index_errors) do
      notify.warn("index " .. e)
    end
    notify.info(("release %s: %d task(s) set to open"):format(key, #done.changed))
  end
  if ctx.flags.yes then
    run()
    return
  end
  local ask = confirm_fn or confirm.yesno
  ask(
    ("Set the %d parked task(s) that wait for '%s' to open?"):format(#plan.ids, key),
    "release",
    function(yes)
      if yes then
        run()
      end
    end
  )
end

---`:Tasks list [<area>|all] [filters] [--to=] [--format=]`
---@param ctx table  composer context
function M.list(ctx)
  if not no_stray_words(ctx) then
    return
  end
  if not apply_list(ctx, {}) then
    return
  end
  local flags = ctx.flags
  local target, terr = view.parse_target(flags.to)
  if terr then
    notify.error(terr)
    return
  end
  local filter, ferr = filter_opts.parse({
    status = flags.status,
    prio = flags.prio,
    effort = flags.effort,
    kind = flags.kind,
    category = flags.category,
    severity = flags.severity,
    waits_for = flags["waits-for"],
    value = flags.value,
    actor = flags.actor,
    tag = flags.tag,
    stale = flags.stale,
    blocked = flags.blocked,
    reminders = flags.reminders,
    overdue = flags.overdue,
    unestimated = flags.unestimated,
    quick_win = flags["quick-win"],
    plan = flags.plan,
    project = flags.project,
    phase = flags.phase,
    sheet = flags.sheet,
    claimed = flags.claimed,
  })
  if not filter then
    notify.error(tostring(ferr))
    return
  end
  local order, oerr = model.parse_sort(flags.sort)
  if not order then
    notify.error(tostring(oerr))
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  filter.ref_opts = { root = root }

  local area = ctx.args.area
  if area == "all" then
    area = nil
  end
  local open, skipped, errors = scan.open_tasks({ root = root, area = area })
  if not open then
    notify.error(tostring(skipped))
    return
  end
  if #errors > 0 then
    notify.warn("cannot read directory " .. table.concat(errors or {}, ", "))
  end
  if flags.ready and flags.waiting then
    notify.error("--ready and --waiting exclude each other")
    return
  end
  -- `--stale=refs` never makes the editor wait for git: every other criterion here, the refs in the background
  -- (`staleness.compute_async`), by the dashboard itself or before the delivery below.
  local refs = filter.stale_refs
  local rest = filter
  if refs then
    rest = vim.tbl_extend("force", {}, filter)
    rest.stale_refs, rest.ref_stale, rest.ref_opts = nil, nil, nil
  end
  local filtered = model.filter(open, rest)
  if flags.ready or flags.waiting then
    -- carried in the filter: the dashboard rescans (live refresh, `r`, a re-sort) and applies the same cut
    filter.readiness = flags.ready and "ready" or "waiting"
    local kept, kerr =
      require("tasks_nvim.plan_scope").filter_readiness(filtered, filter.readiness, root)
    if not kept then
      notify.error(tostring(kerr))
      return
    end
    filtered = kept
  end
  if skipped > 0 then
    notify.warn(
      ("%d task file(s) not listed (missing or unknown status, or done); run :Tasks index --check"):format(
        skipped
      )
    )
  end

  if flags.to == nil and flags.format == nil then
    local dash = M.dashboard
    local builtin = dash == nil
    if builtin then
      dash = function(v)
        return require("tasks_nvim.ui.dash").open(v)
      end
    end
    if dash then
      ---@param shown Tasks.Task[]
      local function open_view(shown)
        dash({
          tasks = model.sort(shown, order),
          area = area,
          filter = filter,
          sort = flags.sort ~= nil and order or nil,
          root = root,
        })
      end
      if not refs or builtin then
        -- the built-in dashboard filters by refs on its own, in the background
        open_view(filtered)
        return
      end
      -- a replaced hook is promised the filtered tasks: it gets them once the background check answered
      notify.info(
        ("--stale=refs: checking the refs of %d task(s) in the background ..."):format(#filtered)
      )
      ref_checks = ref_checks + 1
      staleness.compute_async(filtered, filter.ref_opts, function(rep)
        ref_checks = ref_checks - 1
        open_view(model.filter(filtered, { stale_refs = true, ref_stale = rep.stale }))
      end)
      return
    end
  end

  ---@param shown Tasks.Task[]
  ---@param stale_report Tasks.StalenessReport|nil
  local function deliver(shown, stale_report)
    local ref_note = nil
    if stale_report then
      -- name the files that changed
      local lines = {}
      for _, t in ipairs(shown) do
        lines[#lines + 1] = ("%s: %s"):format(
          t.id,
          staleness.describe(stale_report.stale[t.id] or {}, 3)
        )
      end
      ref_note = #lines > 0 and ("Changed since updated: " .. table.concat(lines, " | ")) or nil
      for _, n in ipairs(stale_report.notes) do
        notify.warn(n)
      end
      notify.info(
        ("--stale=refs: %d file(s) of %d task(s) checked, %d ref(s) found nowhere, %d skipped"):format(
          stale_report.files,
          stale_report.tasks,
          stale_report.unresolved,
          stale_report.skipped
        )
      )
    end
    if #shown == 0 then
      notify.info("no open task matches")
      return
    end

    local label = area or "alle Bereiche"
    unless_overwrite_refused(target, flags.force, function(force)
      local ok, err = view.deliver(shown, target, {
        force = force,
        format = flags.format,
        heading = ("Offene Tasks — %s (%d)"):format(label, #shown),
        note = (function()
          local base = filter_note(flags)
          if ref_note then
            return base and (base .. "\n\n" .. ref_note) or ref_note
          end
          return base
        end)(),
        title = "tasks://tasks/" .. (area or "all"),
      })
      if not ok then
        notify.error(("cannot deliver the task list: %s"):format(tostring(err)))
        return
      end
      notify.info(("%d open task(s) -> %s"):format(#shown, flags.to or "buffer"))
    end)
  end

  if not refs then
    deliver(model.sort(filtered, order), nil)
    return
  end
  notify.info(
    ("--stale=refs: checking the refs of %d task(s) in the background ..."):format(#filtered)
  )
  ref_checks = ref_checks + 1
  staleness.compute_async(filtered, filter.ref_opts, function(rep)
    ref_checks = ref_checks - 1
    local kept = model.filter(filtered, { stale_refs = true, ref_stale = rep.stale })
    deliver(model.sort(kept, order), rep)
  end)
end

---How many `--stale=refs` deliveries (`list`, `plan`, `estimate`, `quickwins`) still wait for their background check
---(specs and sheets wait for 0).
---@return integer
function M.pending_ref_checks()
  return ref_checks
end

---`:Tasks index [<area>] [--all] [--check]`
---@param ctx table
function M.index(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local area = ctx.args.area
  if ctx.flags.all then
    area = nil
  end

  if ctx.flags.check then
    local res, err = check.run({ root = root, area = area })
    if not res then
      notify.error(tostring(err))
      return
    end
    local lines = {}
    for _, f in ipairs(res.findings) do
      lines[#lines + 1] = check.format(f, root)
    end
    for _, f in ipairs(res.hints or {}) do
      lines[#lines + 1] = check.format(f, root)
    end
    local summary = ("tasks check: %d finding(s) (%d error, %d warning, %d hint) in %d area(s), %d task file(s) read"):format(
      #res.findings,
      res.errors,
      res.warnings,
      #(res.hints or {}),
      res.areas,
      res.tasks
    )
    local level = (not res.ok) and "error" or (res.warnings > 0 and "warn" or "info")
    report(level, summary, lines, "tasks://tasks-check")
    return
  end

  local results, errors
  if area then
    local res, err = index.write_area(area, { root = root })
    results = res and { res } or {}
    errors = err and { area .. ": " .. err } or {}
  else
    results, errors = index.write_all({ root = root })
  end
  if not results then
    notify.error(tostring(errors[1]))
    return
  end
  local counts = { written = 0, removed = 0, unchanged = 0, stale = 0 }
  local lines = {}
  for _, r in ipairs(results) do
    counts[r.action] = counts[r.action] + 1
    if r.action ~= "unchanged" then
      lines[#lines + 1] = ("%s  %s  (%d open)"):format(r.action, rel(r.path, root), r.open)
    end
  end
  for _, e in ipairs(errors) do
    lines[#lines + 1] = "error  " .. e
  end
  local summary = ("tasks index: %d area(s), %d written, %d removed, %d unchanged, %d error(s)"):format(
    #results,
    counts.written,
    counts.removed,
    counts.unchanged,
    #errors
  )
  report(#errors > 0 and "error" or "info", summary, lines, "tasks://tasks-index")
end

-- ── task new ─────────────────────────────────────────────────────────────────

---Ask for the fields a `task new` call did not carry. Uses `ui.kit.form`
---(ui.nvim) when it is installed, else a chain of `vim.ui.input` prompts.
---`cb(nil)` means cancelled; otherwise a map of the non-empty answers.
---@param given table<string, string>  kv values already supplied
---@param cb fun(values: table<string, string>|nil)
function M.ask_new_fields(given, cb)
  ---@type { name: string, label: string, required?: boolean, default?: string }[]
  local fields = { { name = "title", label = "Title", required = true } }
  if not given.kind then
    fields[#fields + 1] = {
      name = "kind",
      label = "Kind (" .. table.concat(model.KINDS, "|") .. ")",
      default = "task",
    }
  end
  if not given.prio then
    fields[#fields + 1] = { name = "prio", label = "Prio (1|2|3, empty: none)" }
  end
  if not given.effort then
    fields[#fields + 1] = { name = "effort", label = "Effort (XS|S|M|L|XL|0.5d, empty: none)" }
  end

  ---@param raw table<string, string>
  local function finish(raw)
    local values = {}
    for k, v in pairs(raw) do
      local t = vim.trim(v or "")
      if t ~= "" then
        values[k] = t
      end
    end
    cb(values)
  end

  local kit = soft.check({ "form" }, pcall(require, "ui.kit"))
  if kit then
    kit.form({
      fields = fields,
      on_submit = finish,
      on_cancel = function()
        cb(nil)
      end,
    })
    return
  end

  local answers = {}
  local function step(i)
    local field = fields[i]
    if not field then
      finish(answers)
      return
    end
    vim.ui.input({ prompt = field.label .. ": ", default = field.default }, function(value)
      if value == nil then
        if field.required then
          cb(nil)
          return
        end
        value = field.default or ""
      end
      answers[field.name] = value
      step(i + 1)
    end)
  end
  step(1)
end

---Form seam: `:Tasks new` without arguments calls it instead of
---opening the form buffer of `tasks_form`. Same signature as `tasks_form.open`.
---@type (fun(opts: table): any)|nil
M.form_open = nil

---Explorer seam: shows a folder after a task with assets was created.
---`nil` means filetree.nvim (`:Filetree open`), else the built-in `:edit <dir>`.
---@type (fun(dir: string): any)|nil
M.explorer_open = nil

---Open `dir` in a file explorer: filetree.nvim when its command exists, else
---Neovim's own directory browser.
---@param dir string
local function open_explorer(dir)
  if M.explorer_open then
    M.explorer_open(dir)
    return
  end
  if vim.fn.exists(":Filetree") == 2 then
    -- Table form: the argument reaches the command as one word, no `fnameescape` backslashes to undo.
    local ok = pcall(vim.cmd, { cmd = "Filetree", args = { "open", dir } })
    if ok then
      return
    end
  end
  pcall(vim.cmd, "edit " .. vim.fn.fnameescape(dir))
end

---@see open_explorer
M.open_explorer = open_explorer

---The form flow of `:Tasks new` without arguments: a Markdown form
---(`tasks.form`), then the question "attach assets?", then `mutate.new` -- the
---one write path the CLI uses too. A failure shows in the form, which stays
---open with everything typed; cancelling creates nothing.
---@param given table<string, string>  kv values from the command line, pre-ticked
function M.task_new_form(given)
  local root = vault_root()
  if not root then
    return
  end
  local areas = {}
  for _, a in ipairs(vault.areas(root)) do
    areas[#areas + 1] = a.name
  end
  if #areas == 0 then
    -- No area can pass, so say so before a form is typed that cannot be submitted (it still opens: the report
    -- at the top of the submit says the same).
    notify.warn(require("tasks_nvim.form").no_areas_message(root))
  end
  local ticks = {}
  for _, key in ipairs({ "kind", "prio", "effort", "value", "actor", "severity", "status" }) do
    ticks[key] = given[key]
  end
  if given.category then
    ticks.category = vim.split(given.category, ",", { trimempty = true })
  end
  if given.scope then
    ticks.scope = vim.split(given.scope, ",", { trimempty = true })
  end

  local ui = require("tasks_nvim.ui.form")
  local open = M.form_open or ui.open
  -- No "busy" flag: a second `<C-s>` only reopens the dialog (the kit holds one at a time and calls back only
  -- on an answer), whereas a flag that waited for a callback stayed set when the dialog was closed from outside.
  open({
    areas = areas,
    root = root,
    area = given.area,
    sections = given.acceptance and { acceptance = given.acceptance } or nil,
    title = given.title,
    summary = given.summary,
    mode = given.mode,
    tags = given.tags,
    refs = given.refs,
    links = given.links,
    icon = given.icon,
    cover = given.cover,
    after = given.after,
    plan = given.plan,
    project = given.project,
    phase = given.phase,
    due = given.due,
    start = given.start,
    ticks = ticks,
    on_cancel = function()
      notify.info("task new cancelled")
    end,
    on_submit = function(values, buf)
      -- "No" is first (the dialog starts on it); a dismissed dialog (Esc, `q`) answers nil, which is not "No".
      -- `confirm.choose` itself, not `M.chooser`: that seam stands in for the dialog of `estimate --walk`, and a
      -- scripted walk must not answer this question with its own choices.
      confirm.choose(
        "Attach assets (screenshots, logs) to the new task?\n\nYes makes a folder task with an assets/ folder and opens the file explorer on it.\nA screenshot makes the folder task and attaches the clipboard image (else the newest screenshot) to it.\nEsc goes back to the form: nothing is created.",
        { "No", "Yes, attach assets", "Yes, attach a screenshot" },
        function(picked)
          -- Only the three answers create anything. Esc, `q`, a dialog that could not open: "not now" -- nothing is
          -- written and the form stays open with what was typed.
          if picked ~= 1 and picked ~= 2 and picked ~= 3 then
            notify.info("task not created: the form is still open")
            return
          end
          local with_screenshot = picked == 3
          local with_assets = picked == 2 or with_screenshot
          -- order= is no field of the form: it goes on as it was typed on the command line (after, plan, phase, due
          -- and start are in the form, typed there or put in by the command line)
          local carried = { order = given.order }
          local opts = vim.tbl_extend("force", carried, values.opts, { folder = with_assets })
          -- The range ref is typed into the form as text, and a text field cannot hold a comma (`a,b.lua:5`): when the
          -- user left the line alone, the ref goes on as the list it is.
          if
            given.ref_list
            and vim.trim(tostring(values.opts.refs or "")) == vim.trim(tostring(given.refs or ""))
          then
            opts.refs = given.ref_list
          end
          local function show_problems(msgs)
            if buf and vim.api.nvim_buf_is_valid(buf) then
              ui.show_errors(buf, msgs)
            else
              notify.error(table.concat(msgs, "\n"))
            end
          end
          -- Several areas (`a, b`): one task in each. Every area is tried as a dry run first, so a bad one stops
          -- the whole thing and the form stays open with nothing written (a retry would double the others).
          local names = values.areas or { values.area }
          if #names > 1 then
            local problems = {}
            for _, name in ipairs(names) do
              local _, perr = mutate.new(name, vim.tbl_extend("force", opts, { dry_run = true }))
              if perr then
                problems[#problems + 1] = name .. ": " .. tostring(perr)
              end
            end
            if #problems > 0 then
              show_problems(problems)
              return
            end
          end
          ---@type table[]
          local created = {}
          for _, name in ipairs(names) do
            local r, err = mutate.new(name, opts)
            if not r then
              if #created == 0 then
                show_problems({ tostring(err) })
                return
              end
              -- Some tasks exist already: closing the form is the honest thing, a resubmit would double them.
              local ids = {}
              for _, m in ipairs(created) do
                ids[#ids + 1] = m.id
              end
              notify.error(
                ("%s: %s -- created before: %s"):format(
                  name,
                  tostring(err),
                  table.concat(ids, ", ")
                )
              )
              break
            end
            created[#created + 1] = r
          end
          local res = created[1]
          if buf then
            ui.close(buf)
          end
          local ids = {}
          for _, m in ipairs(created) do
            ids[#ids + 1] = m.id
            if m.index_err then
              notify.warn("task created, but the index was not updated: " .. m.index_err)
            end
            if m.ambiguous then
              notify.warn(require("tasks_nvim.wikilinks").ambiguity_message(m.ambiguous))
            end
          end
          -- The block of the marked code first: the file is complete before it is opened or offered to an app. It
          -- goes in only while the ref line of the form is as the selection made it (a person who cleared the ref
          -- does not want the code of it either).
          local items = {}
          if given.code_ref and opts.refs == given.ref_list then
            for i, m in ipairs(created) do
              items[#items + 1] = { area = names[i], id = m.id, path = m.path }
            end
          end
          M.write_code_refs(given.code_ref, items, function()
            notify.info(("created %s"):format(table.concat(ids, ", ")))
            open_file(res.path)
            -- A task made from a selection (it carries the ref): show it in tasks-desktop or tasks-web as
            -- `new.open_after` says.
            if given.refs then
              require("tasks_nvim.open_app").after_new(ids[1], function(msg, level)
                if level == "warn" then
                  notify.warn(msg)
                else
                  notify.info("opened " .. msg)
                end
              end)
            end
            if with_screenshot then
              -- After the task is open: the link lands in it, at the cursor. A task without a screenshot stays
              -- (it is made, only the attachment failed, and `M.attach_screenshot` says so).
              M.attach_screenshot(res.id)
            elseif with_assets then
              local assets = vim.fs.dirname(res.path) .. "/" .. mutate.ASSETS_DIR
              local made, merr = fsio.mkdirp(assets)
              if made then
                open_explorer(assets)
              else
                notify.warn(
                  ("task created, but %s could not be created: %s"):format(assets, tostring(merr))
                )
              end
            end
          end)
        end
      )
    end,
  })
end

---Writes the `code-ref/1` block of a selection (`tasks_nvim.code_ref`) into the tasks just created, then `done()`:
---the block stands in the file before the task is opened or offered to an app. In a private area (`new.private_areas`,
---`new.private_vaults`) the excerpt goes in only after a yes; a no (or a dismissed dialog) writes the reference without
---it. A block the check of the reader refuses is never written; the task stays, the reason is told.
---@param doc table|nil  the document of `code_ref.capture`
---@param items { area: string, id: string, path: string }[]
---@param done fun()
---@param deps? { confirm?: fun(msg: string, label: string, cb: fun(yes: boolean)) }
function M.write_code_refs(doc, items, done, deps)
  if not doc or #items == 0 then
    done()
    return
  end
  local code_ref = require("tasks_nvim.code_ref")
  local root = vault.root()
  local private = {}
  local any_private = false
  for i, item in ipairs(items) do
    private[i] = code_ref.is_private(item.area, root)
    any_private = any_private or private[i]
  end
  local function write(excerpt_ok)
    local plain, perr = code_ref.render(code_ref.strip_excerpt(doc))
    local full, ferr = code_ref.render(doc)
    for i, item in ipairs(items) do
      local block, err = plain, perr
      if not private[i] or excerpt_ok then
        block, err = full, ferr
      end
      if not block then
        notify.warn(("no code-ref block in %s: %s"):format(item.id, table.concat(err or {}, "; ")))
      else
        local ok, ierr = code_ref.insert(item.path, block)
        if not ok then
          notify.warn(("no code-ref block in %s: %s"):format(item.id, tostring(ierr)))
        end
      end
    end
    done()
  end
  if any_private and doc.excerpt then
    local ask = (deps and deps.confirm)
      or function(msg, label, cb)
        confirm.yesno(msg, label, cb)
      end
    ask(
      "This area is private. Write the code excerpt (up to 4 KiB of the marked lines) into the task?\n\nNo writes the reference only: repository, commit, file and lines.",
      "write the excerpt",
      function(yes)
        write(yes == true)
      end
    )
    return
  end
  write(true)
end

---The ref of a range in a file: the path relative to the git root of the file (so it holds whatever the working
---directory of the editor is; without a git root, relative to the working directory as before) and the lines
---(`lua/a.lua:5`, `lua/a.lua:5-12`), the forms the staleness check understands.
---@param file string  absolute or relative path of the file
---@param first_line integer
---@param last_line integer
---@return string ref
function M.range_ref(file, first_line, last_line)
  local where = require("tasks_nvim.code_ref").relative(file)
  if last_line > first_line then
    return ("%s:%d-%d"):format(where, first_line, last_line)
  end
  return ("%s:%d"):format(where, first_line)
end

---The code a range names: `:'<,'>Tasks new` (from a visual selection or any `:5,10Tasks new`) makes a task about
---those lines. `ref` is the buffer's file relative to its git root plus the lines (`lua/a.lua:5` or `lua/a.lua:5-12`,
---see `range_ref`; a ref the staleness check understands), `text` the first non-blank line, squeezed and cut, for a title nobody typed.
---@param ctx table  composer context; `ctx.range = { range, line1, line2 }`
---@param buf? integer  default: the current buffer
---@return { ref?: string, text?: string, code_ref?: table, code_ref_reason?: string }|nil source  # nil: no range given
function M.range_source(ctx, buf)
  local r = ctx.range
  if not r or (r.range or 0) == 0 then
    return nil
  end
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local first_line = math.max(1, math.min(r.line1 or 1, last))
  local last_line = math.max(first_line, math.min(r.line2 or first_line, last))
  local source = {}
  local name = vim.api.nvim_buf_get_name(buf)
  -- A real file only: `term://`, `tasks://` and the like name no path a ref could point at.
  if name ~= "" and not name:match("^%a[%w+.-]*://") and vim.bo[buf].buftype == "" then
    source.ref = M.range_ref(name, first_line, last_line)
    -- the code-ref/1 block of the task (`tasks_nvim.code_ref`); the reason when there is none
    source.code_ref, source.code_ref_reason =
      require("tasks_nvim.code_ref").capture(buf, first_line, last_line)
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, first_line - 1, last_line, false)) do
    local squeezed = vim.trim((line:gsub("%s+", " ")))
    if squeezed ~= "" then
      source.text = vim.fn.strcharpart(squeezed, 0, 80)
      break
    end
  end
  return source
end

---The text of `:Tasks new --draft`: the words after it, then the selected lines (a range), joined by a blank line.
---@param ctx table
---@param buf? integer
---@return string
function M.draft_text(ctx, buf)
  local parts = {}
  local words = {}
  if ctx.args and ctx.args.area and ctx.args.area ~= "" then
    words[1] = ctx.args.area
  end
  vim.list_extend(words, ctx.rest or {})
  local typed = vim.trim(unquote(table.concat(words, " ")))
  if typed ~= "" then
    parts[#parts + 1] = typed
  end
  local r = ctx.range
  if r and (r.range or 0) > 0 then
    buf = buf or vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(buf) then
      local last = vim.api.nvim_buf_line_count(buf)
      local first_line = math.max(1, math.min(r.line1 or 1, last))
      local last_line = math.max(first_line, math.min(r.line2 or first_line, last))
      local selected = vim.trim(
        table.concat(vim.api.nvim_buf_get_lines(buf, first_line - 1, last_line, false), "\n")
      )
      if selected ~= "" then
        parts[#parts + 1] = selected
      end
    end
  end
  return table.concat(parts, "\n\n")
end

---`:Tasks new --draft <text>` (or over a selection): the fields of a new task proposed from a free text
---(`tasks_nvim.draft`), by ai-desktop's job `draft-task` or, without a running ai-desktop, one answer of ai.nvim. The
---draft fills the form of `:Tasks new`; nothing is created before `<C-s>`. The area is not known yet, so the
---strictest class holds: ai-desktop's jobs model, when it is not local, is used only after a yes here, and ai.nvim is
---asked only after a yes.
---@param ctx table
---@param deps? table Stand-ins for the specs: `state`, `ai_desktop`, `ai_nvim`, `choices`, `hand_over`, `record`,
---  `watch`, `confirm_run`, `drop_job`, `confirm`, `form`, `root`.
function M.task_new_draft(ctx, deps)
  deps = deps or {}
  local ai = require("tasks_nvim.ai")
  local agent = require("tasks_nvim.agent")
  local draft = require("tasks_nvim.draft")
  local state = deps.state or ai.state()
  if not state.on then
    notify.error(
      state.setting == false and "new --draft: the AI functions are off (setup({ ai = false }))"
        or "new --draft: neither ai-desktop nor ai.nvim is found on this machine"
    )
    return
  end
  local text = M.draft_text(ctx)
  if text == "" then
    notify.error(
      "new --draft: give a text (the words after --draft) or select the lines to draft from"
    )
    return
  end
  if #text > draft.MAX_TEXT then
    notify.error(("new --draft: the text is larger than %d KiB"):format(draft.MAX_TEXT / 1024))
    return
  end
  local root = deps.root or vault_root()
  if not root then
    return
  end
  local choices = deps.choices or draft.choices(root)
  if #choices.areas == 0 then
    notify.error(require("tasks_nvim.form").no_areas_message(root))
    return
  end
  local confirm_fn = deps.confirm
    or function(msg, label, cb)
      require("tasks_nvim.ui.confirm").yesno(msg, label, cb)
    end
  local source = M.range_source(ctx)

  ---@param d Tasks.Draft
  local function fill(d)
    local given = draft.given(d)
    if source and source.ref then
      given.refs, given.ref_list = source.ref, { source.ref }
      given.code_ref = source.code_ref
    end
    if #d.dropped > 0 then
      notify.info(
        "new --draft: left out, not values of this vault: " .. table.concat(d.dropped, ", ")
      )
    end
    notify.info("new --draft: the form is filled in; <C-s> creates the task, q drops it")
    local form = deps.form or M.task_new_form
    form(given)
  end

  local desktop = deps.ai_desktop or ai.ai_desktop()
  if desktop.running then
    local hand_over = deps.hand_over or agent.hand_over
    notify.info("new --draft: asking ai-desktop ...")
    hand_over(draft.payload(text, root, choices), function(herr, res)
      if herr or not res then
        notify.error("new --draft: " .. (herr or "no answer"))
        return
      end
      -- The ai-desktop the hand-over proved (`res.peer`): its job is there, and every later request proves it again.
      local record = res.peer or deps.record or ai.hub_record()
      if not record then
        notify.error("new --draft: ai-desktop is gone")
        return
      end
      local function watch_job()
        local watch = deps.watch or agent.watch
        watch(record.port, res.job_id, function(werr, job)
          if werr or not job then
            notify.error("new --draft: " .. tostring(werr))
            return
          end
          if job.status ~= "done" then
            notify.error(
              ("new --draft: the job is %s: %s"):format(
                job.status,
                tostring(job.error or "no answer")
              )
            )
            return
          end
          local d, derr
          if type(job.draft) == "table" then
            d, derr = draft.check(job.draft, choices)
            if d then
              d.dropped = vim.list_extend(draft.dropped_by(job.draft), d.dropped)
            end
          else
            derr = type(job.draft_error) == "string" and job.draft_error
              or "ai-desktop gave no draft"
          end
          if not d then
            notify.error("new --draft: " .. tostring(derr) .. "; nothing filled in")
            return
          end
          fill(d)
        end, { interval_ms = 1000, max_ms = 10 * 60 * 1000 })
      end
      if res.status ~= "needs_confirmation" then
        watch_job()
        return
      end
      confirm_fn(
        "The area of the new task is not chosen yet, so the text counts as private, and the model of ai-desktop's jobs does not run on this machine. Send the text there anyway?",
        "send",
        function(yes)
          if not yes then
            -- Nothing goes to a model; the waiting job (with the text, in the memory of ai-desktop) is put away.
            local drop_job = deps.drop_job or agent.drop_job
            drop_job(record, res.job_id, function(derr, outcome)
              if derr then
                notify.info(
                  "new --draft: nothing sent from here; the job still waits in the dashboard of ai-desktop ("
                    .. derr
                    .. ")"
                )
              elseif outcome == "dropped" or outcome == "gone" then
                notify.info("new --draft: nothing sent")
              else
                -- Confirmed in the dashboard of ai-desktop meanwhile: the text went to its model from there.
                notify.warn(
                  ("new --draft: the job was confirmed in the dashboard of ai-desktop meanwhile (%s); the text went to its model from there, the job was left as it is"):format(
                    tostring(outcome)
                  )
                )
              end
            end)
            return
          end
          local confirm_run = deps.confirm_run or agent.confirm_run
          confirm_run(record, res.job_id, function(cerr)
            if cerr then
              notify.error("new --draft: " .. cerr)
              return
            end
            watch_job()
          end)
        end
      )
    end, { allow_foreground = function() end })
    return
  end
  local ai_nvim = deps.ai_nvim
  if ai_nvim == nil then
    local has_ai, mod = pcall(require, "ai")
    ai_nvim = has_ai and type(mod) == "table" and type(mod.ask) == "function" and mod or false
  end
  if not ai_nvim then
    notify.error(
      desktop.installed
          and "new --draft: ai-desktop is installed but not running: start it, then :Tasks new --draft again"
        or "new --draft: there is no ai-desktop and no ai.nvim to ask"
    )
    return
  end
  local prompt = draft.prompt(text, choices)
  -- UI-03: a fallback says so; and ai.nvim may use a model outside this machine, so it asks first.
  confirm_fn(
    ("%s; ai.nvim answers once instead. The area is not chosen yet, so the text counts as private, and ai.nvim may send it to a model outside this machine. Send the text (%d characters)?"):format(
      desktop.installed and "ai-desktop is installed but not running"
        or "No ai-desktop on this machine",
      #text
    ),
    "send",
    function(yes)
      if not yes then
        notify.info("new --draft: nothing sent")
        return
      end
      notify.info("new --draft: waiting for the answer of ai.nvim ...")
      ai_nvim.ask({ prompt = prompt, context = {} }, function(ok, res)
        vim.schedule(function()
          if not ok then
            local why = type(res) == "table" and res.message or tostring(res)
            notify.error("new --draft: ai.nvim: " .. tostring(why))
            return
          end
          local d, derr = draft.extract(tostring(type(res) == "table" and res.text or ""), choices)
          if not d then
            notify.error("new --draft: " .. tostring(derr) .. "; nothing filled in")
            return
          end
          fill(d)
        end)
      end)
    end
  )
end

---`:Tasks new [<area> [title...]] [kind= prio= effort= tags= status=]`. With a range, the task is about those lines:
---it gets a `refs:` entry for them, and the first selected line as its title when none was typed.
---@param ctx table
function M.task_new(ctx)
  if ctx.flags and ctx.flags.draft then
    M.task_new_draft(ctx)
    return
  end
  local area = ctx.args.area
  local source = M.range_source(ctx)
  if area == nil or area == "" then
    local given = {}
    for _, key in ipairs({
      "kind",
      "prio",
      "effort",
      "value",
      "actor",
      "tags",
      "links",
      "icon",
      "cover",
      "category",
      "scope",
      "severity",
      "status",
      "mode",
      "after",
      "plan",
      "project",
      "phase",
      "due",
      "start",
      -- not a field of the form: carried through to `mutate.new` as it was typed
      "order",
    }) do
      if ctx.kv[key] ~= nil and ctx.kv[key] ~= "" then
        given[key] = ctx.kv[key]
      end
    end
    if source then
      given.refs, given.title = source.ref, source.text
      given.ref_list = source.ref and { source.ref } or nil
      given.code_ref = source.code_ref
      if source.ref and not source.code_ref and source.code_ref_reason then
        notify.info("no code-ref block: " .. source.code_ref_reason)
      end
    end
    M.task_new_form(given)
    return
  end
  -- The route takes any first word (it may be the text of `--draft`): the area is checked here.
  local root = vault.root()
  if root then
    local names = {}
    for _, a in ipairs(vault.areas(root)) do
      names[#names + 1] = a.name
    end
    if not vim.tbl_contains(names, area) then
      notify.error(vault.not_an_area_message(area, names))
      return
    end
  end
  local title = unquote(table.concat(ctx.rest, " "))
  if title == "" and source and source.text then
    title = source.text
  end
  local given = {}
  for _, key in ipairs({
    "kind",
    "prio",
    "effort",
    "value",
    "actor",
    "after",
    "order",
    "plan",
    "project",
    "phase",
    "tags",
    "links",
    "icon",
    "cover",
    "category",
    "scope",
    "severity",
    "status",
    "waits_for",
  }) do
    if ctx.kv[key] ~= nil and ctx.kv[key] ~= "" then
      given[key] = ctx.kv[key]
    end
  end

  ---@param values table<string, string>
  local function create(values)
    local res, err = mutate.new(area, {
      title = values.title,
      kind = values.kind,
      prio = values.prio,
      effort = values.effort,
      tags = values.tags,
      category = values.category,
      scope = values.scope,
      severity = values.severity,
      value = values.value,
      actor = values.actor,
      after = values.after,
      order = values.order,
      plan = values.plan,
      project = values.project,
      phase = values.phase,
      due = ctx.kv.due,
      start = ctx.kv.start,
      repeat_every = ctx.kv["repeat"],
      repeat_from = ctx.kv.repeat_from,
      repeat_after = ctx.kv.repeat_after,
      status = values.status,
      waits_for = values.waits_for,
      web_links = values.links,
      icon = values.icon,
      cover = values.cover,
      -- a list: a string would be split at the commas of a file name (`a,b.lua`)
      refs = source and source.ref and { source.ref } or nil,
      folder = ctx.flags.folder == true,
    })
    if not res then
      notify.error(tostring(err))
      return
    end
    if res.index_err then
      notify.warn("task created, but the index was not updated: " .. res.index_err)
    end
    if res.ambiguous then
      notify.warn(require("tasks_nvim.wikilinks").ambiguity_message(res.ambiguous))
    end
    if source and source.ref and not source.code_ref and source.code_ref_reason then
      notify.info("no code-ref block: " .. source.code_ref_reason)
    end
    -- The code-ref block first (it asks in a private area), then the task is opened.
    local items = source and source.code_ref and { { area = area, id = res.id, path = res.path } }
      or {}
    M.write_code_refs(source and source.code_ref, items, function()
      notify.info(("created %s"):format(res.id))
      open_file(res.path)
      -- A task made from a selection: show it in tasks-desktop or tasks-web as `new.open_after` says.
      if source then
        require("tasks_nvim.open_app").after_new(res.id, function(msg, level)
          if level == "warn" then
            notify.warn(msg)
          else
            notify.info("opened " .. msg)
          end
        end)
      end
    end)
  end

  if title ~= "" then
    create(vim.tbl_extend("force", given, { title = title }))
    return
  end
  M.ask_new_fields(given, function(values)
    if not values then
      notify.info("task new cancelled")
      return
    end
    if not values.title then
      notify.warn("no title given, nothing created")
      return
    end
    create(vim.tbl_extend("force", given, values))
  end)
end

-- ── task set ─────────────────────────────────────────────────────────────────

---Turn `key=value` tokens into a patch. A value may contain spaces: a token
---that does not start with a known `key=` continues the value before it, so
---`title=Fix the thing status=doing` sets two keys. An empty value (`kind=`)
---removes the key.
---@param tokens string[]
---@param known string[]  accepted keys
---@return table<string, any>|nil patch
---@return string|nil err
function M.parse_assignments(tokens, known)
  local is_known = {}
  for _, k in ipairs(known) do
    is_known[k] = true
  end
  ---@type { key: string, words: string[] }[]
  local items = {}
  for _, tok in ipairs(tokens) do
    local key, value = tok:match("^([%a_][%w_]*)=(.*)$")
    if key and is_known[key] then
      items[#items + 1] = { key = key, words = { value } }
    elseif #items > 0 then
      local words = items[#items].words
      words[#words + 1] = tok
    elseif key then
      return nil, ("unknown field '%s' (settable: %s)"):format(key, table.concat(known, ", "))
    else
      return nil, ("expected key=value, got '%s'"):format(tok)
    end
  end
  if #items == 0 then
    return nil, "nothing to set (expected key=value ...)"
  end
  local patch = {}
  for _, item in ipairs(items) do
    if patch[item.key] ~= nil then
      return nil, ("'%s' given twice"):format(item.key)
    end
    local text = vim.trim(table.concat(item.words, " "))
    patch[item.key] = text == "" and mutate.REMOVE or unquote(text)
  end
  return patch, nil
end

---`:Tasks set <id> key=value ...`
---@param ctx table
function M.task_set(ctx)
  local fargs = ctx.raw.fargs or {}
  local tokens = {}
  for i = #ctx.path + 2, #fargs do
    tokens[#tokens + 1] = fargs[i]
  end
  local patch, perr = M.parse_assignments(tokens, mutate.SETTABLE)
  if not patch then
    notify.error(tostring(perr))
    return
  end
  local res, err = mutate.set(ctx.args.id, patch)
  if not res then
    notify.error(tostring(err))
    return
  end
  if res.index_err then
    notify.warn("task changed, but the index was not updated: " .. res.index_err)
  end
  if res.changed then
    refresh_buffers(res.path)
  end
  notify.info(("set %s: %s"):format(res.id, res.changed and "changed" or "unchanged"))
end

-- ── task answer ──────────────────────────────────────────────────────────────

---Write the answer into the file and say so.
---@param id string
---@param question string|integer
---@param option integer  # 0 takes the answer back.
local function write_answer(id, question, option)
  local res, err = mutate.edit_text(id, function(text)
    local new_text, info, qerr = questions.answer(text, question, option)
    if not new_text then
      return nil, qerr
    end
    return new_text, nil, { key = info and info.key or tostring(question) }
  end, {})
  if not res then
    notify.error(tostring(err))
    return
  end
  if res.changed then
    refresh_buffers(res.path)
  end
  notify.info(
    ("answer %s %s: %s"):format(
      res.id,
      res.extra and res.extra.key or tostring(question),
      res.changed and "changed" or "unchanged"
    )
  )
end

---The id of the task the current buffer shows (its file, or any file of a folder task's folder), or nil. Paths
---compare as the file system does (`fsio.same_path`: case-insensitive on Windows).
---@return string|nil
local function buffer_task_id()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return nil
  end
  local want = vim.fn.fnamemodify(name, ":p")
  local dir = vim.fs.dirname(fsio.norm(want))
  for _, t in ipairs(scan.all() or {}) do
    if
      t.path
      and (
        fsio.same_path(t.path, want) or (t.folder and fsio.same_path(vim.fs.dirname(t.path), dir))
      )
    then
      return t.id
    end
  end
  return nil
end

---`:Tasks sheet-run [<id>] [--dry-run]`: run the test sheets of a live-check task now (`tasks_nvim.sheet_run`, which
---starts testing.nvim's `testing sheets run`); the result is written into the task's block and said in one line.
---@param ctx table
---@param system? function A stand-in for `vim.system` (specs).
function M.task_sheet_run(ctx, system)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local id = ctx.args.id or buffer_task_id()
  if not id then
    notify.error("sheet-run: name a task (area/slug), or run it from a task's buffer")
    return
  end
  if not id:match("^[%w_][^/]*/[^/]+$") then
    notify.error("sheet-run: " .. id .. " is no task id (area/slug)")
    return
  end
  local root, rerr = require("tasks_nvim.vault").root()
  if not root then
    notify.error(tostring(rerr))
    return
  end
  local cfg = require("tasks_nvim.config").get().sheet_run or {}
  notify.info(id .. ": running its test sheets ...")
  require("tasks_nvim.sheet_run").run(id, {
    vault = root,
    cli = cfg.testing_cli,
    dry_run = ctx.flags["dry-run"] == true,
  }, function(res)
    if res.code == 0 then
      notify.info(id .. ": " .. res.summary)
    else
      notify.error(id .. ": " .. res.summary)
    end
    -- the engine rewrote the task file: an open buffer of it shows the new block
    pcall(vim.cmd.checktime)
  end, system)
end

---The task an AI step is about: the id given, the task of a hand-over buffer (`tasks://sheet-ai/<step>/<id>`), else
---the task of the current buffer.
---@param ctx table
---@return string|nil
local function ai_task_id(ctx)
  if ctx.args.id then
    return ctx.args.id
  end
  local from_name = vim.api.nvim_buf_get_name(0):match("^tasks://sheet%-ai/%a+/(.+)$")
  return from_name or buffer_task_id()
end

---Show a hand-over document in a scratch buffer of its own and put it on the clipboard.
---@param step string
---@param id string
---@param doc string
local function show_handover(step, id, doc)
  local name = ("tasks://sheet-ai/%s/%s"):format(step, id)
  -- a second hand-over of the same step and task takes the buffer of the first (a name is unique)
  local buf = -1
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      buf = b
    end
  end
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("botright sbuffer " .. buf)
    end
  else
    vim.cmd("botright new")
    buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    -- hidden, not wiped: a pasted answer survives leaving the window
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, name)
  end
  local lines = vim.split(doc:gsub("\n$", ""), "\n", { plain = true })
  vim.list_extend(lines, {
    "",
    "<!-- Paste the AI's answer below this line, then :Tasks sheet-ai "
      .. (step == "draft" and "accept" or "bug")
      .. " -->",
    "",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.fn.setreg, "+", doc)
  vim.fn.setreg('"', doc)
end

---The answer pasted into the current buffer: the lines after the hand-over's marker line, or the whole buffer.
---@return string
local function pasted_answer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("^<!%-%- Paste the AI's answer below this line") then
      return table.concat(vim.list_slice(lines, i + 1), "\n")
    end
  end
  return table.concat(lines, "\n")
end

---`:Tasks sheet-ai ask`, in a hand-over buffer: send the document above the marker to ai.nvim and put the answer below
---it, where `accept` and `bug` read it. Runs in the editor; the headless way (and with it the app) waits for
---`ai.nvim/headless-jsonl-entry`.
---
---What leaves the machine is exactly the document: no context of ai.nvim's is asked for. The person confirms first,
---since this sends text to a provider and may cost money. Nothing is written but the buffer.
---@param step string The step of the hand-over buffer, `draft` or `explain`.
---@param confirm_fn fun(msg: string, label: string, cb: fun(yes: boolean))
local function ask_model(step, confirm_fn)
  local buf = vim.api.nvim_get_current_buf()
  local function marker_line()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i = #all, 1, -1 do
      if all[i]:match("^<!%-%- Paste the AI's answer below this line") then
        return i, all
      end
    end
  end
  local marker, lines = marker_line()
  if not marker then
    notify.error("sheet-ai ask: no hand-over in this buffer; run :Tasks sheet-ai draft first")
    return
  end
  -- `setup({ ai = false })` turns every AI function of the ai family off: ask sends to ai.nvim, so it refuses.
  if require("tasks_nvim.config").get().ai == false then
    notify.error(
      "sheet-ai ask: the AI functions are off (setup({ ai = false })); paste the document into an AI by hand"
    )
    return
  end
  local has_ai, ai = pcall(require, "ai")
  if not has_ai then
    notify.error("sheet-ai ask: ai.nvim is not available; paste the document into an AI by hand")
    return
  end
  local doc = vim.trim(table.concat(vim.list_slice(lines, 1, marker - 1), "\n"))
  confirm_fn(("Send this hand-over (%d characters) to the AI?"):format(#doc), "send", function(yes)
    if not yes then
      return
    end
    notify.info("sheet-ai ask: waiting for the answer ...")
    ai.ask({ prompt = doc, context = {} }, function(ok, res)
      vim.schedule(function()
        if not ok then
          local why = type(res) == "table" and res.message or tostring(res)
          notify.error("sheet-ai ask: " .. tostring(why))
        elseif not vim.api.nvim_buf_is_valid(buf) then
          notify.warn("sheet-ai ask: the hand-over buffer is gone, the answer with it")
        elseif not marker_line() then
          -- Edited away while the answer was on its way: there is no safe place for it.
          notify.warn("sheet-ai ask: the marker line is gone, the answer was not inserted")
        else
          local answer = vim.split(tostring(res.text or ""), "\r?\n")
          vim.api.nvim_buf_set_lines(buf, (marker_line()), -1, false, answer)
          notify.info(
            ("sheet-ai ask: answered, read it, then :Tasks sheet-ai %s"):format(
              step == "draft" and "accept" or "bug"
            )
          )
        end
      end)
    end)
  end)
end

---`:Tasks sheet-ai draft|explain|accept|bug [<id>]`: stage 0 of the AI link for a live-check task. `draft` and
---`explain` put a hand-over document (testing.nvim's `testing sheets prompt`) into a scratch buffer and onto the
---clipboard; the person pastes it into an AI and the answer back below it. `accept` writes the sheet of that answer
---(testing.nvim's `testing sheets accept`: only when it loads), `bug` creates the bug task it proposes; both ask first.
---@param ctx table
---@param system? function A stand-in for `vim.system` (specs).
---@param confirm_fn? fun(msg: string, label: string, cb: fun(yes: boolean)) A stand-in for the dialog (specs).
function M.task_sheet_ai(ctx, system, confirm_fn)
  local step = ctx.args.step
  if
    #ctx.rest > 0
    or not require("tasks_nvim.sheet_run").AI[step] and step ~= "bug" and step ~= "ask"
  then
    notify.error("usage: :Tasks sheet-ai draft|explain|ask|accept|bug [<id>]")
    return
  end
  if step == "ask" then
    local handed = vim.api.nvim_buf_get_name(0):match("^tasks://sheet%-ai/(%a+)/")
    if not handed then
      notify.error("sheet-ai ask: run it in a hand-over buffer (:Tasks sheet-ai draft|explain)")
      return
    end
    ask_model(handed, confirm_fn or function(msg, label, cb)
      require("tasks_nvim.ui.confirm").yesno(msg, label, cb)
    end)
    return
  end
  local id = ai_task_id(ctx)
  if not id or not id:match("^[%w_][^/]*/[^/]+$") then
    notify.error(
      "sheet-ai: name a task (area/slug), or run it from a task's or a hand-over's buffer"
    )
    return
  end
  local root, rerr = require("tasks_nvim.vault").root()
  if not root then
    notify.error(tostring(rerr))
    return
  end
  local sr = require("tasks_nvim.sheet_run")
  local cfg = require("tasks_nvim.config").get().sheet_run or {}
  local ask = confirm_fn
    or function(msg, label, cb)
      require("tasks_nvim.ui.confirm").yesno(msg, label, cb)
    end
  if step == "draft" or step == "explain" then
    notify.info(
      id .. (step == "draft" and ": building the hand-over ..." or ": running its sheets ...")
    )
    sr.ai(step, id, { vault = root, cli = cfg.testing_cli }, function(res)
      if res.code ~= 0 then
        notify.error(id .. ": " .. res.summary)
      elseif (res.stdout or "") == "" then
        notify.info(id .. ": " .. (res.lines[1] or "nothing to hand over"))
      else
        show_handover(step, id, res.stdout)
        notify.info(
          id .. ": hand-over in the buffer and on the clipboard; paste the answer below it"
        )
      end
    end, system)
    return
  end
  local answer = pasted_answer()
  if step == "bug" then
    local proposal = sr.task_block(answer)
    if not proposal then
      notify.error("sheet-ai bug: no ```task block (title:, summary:) in the answer")
      return
    end
    ask(
      ("Create the bug task %q in %s?"):format(proposal.title, id:match("^[^/]+")),
      "create",
      function(yes)
        if not yes then
          return
        end
        local made, merr = sr.create_bug(proposal, id, root)
        if made then
          notify.info("created " .. made.id)
        else
          notify.error("sheet-ai bug: " .. tostring(merr))
        end
      end
    )
    return
  end
  local lua = sr.lua_block(answer)
  if not lua then
    notify.error("sheet-ai accept: no ```lua block in the answer")
    return
  end
  -- the whole sheet is shown: what is confirmed is what is written
  ask("Write this sheet for " .. id .. "?\n" .. lua, "write", function(yes)
    if not yes then
      return
    end
    local tmp = sr.sheet_file(lua)
    sr.ai("accept", id, { vault = root, cli = cfg.testing_cli, from = tmp }, function(res)
      os.remove(tmp)
      if res.code == 0 then
        notify.info(id .. ": " .. (res.lines[1] or "written"))
      else
        notify.error(id .. ": " .. sr.accept_reason(res))
      end
    end, system)
  end)
end

---`:Tasks task answer <id> [question=q1 option=2|clear]`: with both, the answer is written; without, the open questions
---are asked one after the other (the recommended option is marked), so a decision can be made from the editor.
---@param ctx table
function M.task_answer(ctx)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local id = ctx.args.id
  local task = scan.find(id)
  local summary = task and task.questions
  if not summary then
    notify.error(id .. " has no questions (no `## Offene Fragen` section)")
    return
  end
  local question, choice = ctx.kv.question, ctx.kv.option
  if question ~= nil or choice ~= nil then
    local n = choice == "clear" and 0 or tonumber(choice)
    if question == nil or n == nil then
      notify.error("answer needs question=<q1|#n> and option=<n|clear>")
      return
    end
    write_answer(id, question, n)
    return
  end
  local open = {}
  for _, q in ipairs(summary.items) do
    if not q.answered then
      open[#open + 1] = q
    end
  end
  if #open == 0 then
    notify.info(id .. ": every question is answered")
    return
  end
  local function ask(i)
    local q = open[i]
    if not q then
      return
    end
    local labels = {}
    for _, o in ipairs(q.options) do
      labels[#labels + 1] = o.text .. (o.recommended and "  (recommended)" or "")
    end
    vim.ui.select(
      labels,
      { prompt = q.title .. (q.text ~= "" and (": " .. q.text) or "") },
      function(_, at)
        if at then
          write_answer(id, q.key or q.n, at)
        end
        ask(i + 1)
      end
    )
  end
  ask(1)
end

-- ── task done ────────────────────────────────────────────────────────────────

---What a finish leaves to say: the tasks that still read `blocked` although this was their last blocker (offered to be
---set to open, with a question, never silently), then the next task. Needs somebody to answer; a headless session
---only gets the next-task message.
---@param flow { next?: Tasks.NextPick, plans_closed?: string[], plan_summaries?: table<string, table> }
---@param id string
function M.after_finish(flow, id)
  local nxt = flow.next
  if not nxt then
    return
  end
  local show = function()
    require("tasks_nvim.ui.next_popup").show(nxt, id, flow)
  end
  if #nxt.freed_blocked > 0 and #vim.api.nvim_list_uis() > 0 then
    local names = table.concat(nxt.freed_blocked, "\n")
    confirm.yesno(
      ("These tasks waited only on %s and still say blocked:\n\n%s\n\nSet them to open?"):format(
        id,
        names
      ),
      "set to open",
      function(yes)
        if yes then
          local steps = {}
          for _, task_id in ipairs(nxt.freed_blocked) do
            steps[#steps + 1] = { id = task_id, patch = { status = "open" } }
          end
          local res = require("tasks_nvim.batch").set_many(steps, {})
          local level, text = require("tasks_nvim.ui.dash_core").describe_set("status", res)
          notify[level](text)
        end
        show()
      end
    )
    return
  end
  show()
end

---@param id string
---@param opts { done_in?: string, commits?: string, date?: string }
local function finish_task(id, opts)
  -- every option of the route reaches the finish (`remind` and `outcome` were lost here once)
  local flow, err = done_flow.run(id, {
    done_in = opts.done_in,
    commits = opts.commits,
    date = opts.date,
    remind = opts.remind and (opts.remind:match("^%d+[dw]$") and "+" .. opts.remind or opts.remind)
      or nil,
    outcome = opts.outcome,
    outcome_reason = opts.outcome_reason,
    ci = opts.ci,
    -- a marker block recorded with `--stale=refs` would date its refs with git: the editor leaves it and says so
    defer_stale_refs = true,
  })
  if not flow then
    notify.error(tostring(err))
    return
  end
  local res = flow.done
  if res.already then
    notify.info(("%s is already finished (%s)"):format(id, res.to))
    return
  end
  M.retarget_buffers(res.from, res.to)
  if flow.next_round then
    notify.info(("next round of %s: due %s"):format(flow.next_round.id, flow.next_round.due))
  end
  if flow.routine_ended then
    notify.info(("%s was the last round of its routine"):format(id))
  end
  for _, r in ipairs(flow.routines_started or {}) do
    notify.info(("routine %s starts: due %s"):format(r.id, r.due))
  end
  if res.index_err then
    notify.warn("task finished, but the index was not updated: " .. res.index_err)
  end
  if res.readme == "missing" then
    notify.warn("Backlog/README.md does not exist: no row added for the finished task")
  end
  local root = vault.root()
  local lines = { ("done %s -> %s"):format(id, root and rel(res.to, root) or res.to) }
  -- a milestone this finish reached (or set back to doing), as `tasks done` says it
  for _, m in ipairs(flow.milestones_reached or {}) do
    lines[#lines + 1] = "milestone reached: " .. m
  end
  for _, m in ipairs(flow.milestones_reopened or {}) do
    lines[#lines + 1] = "milestone open again: " .. m
  end
  notify.info(table.concat(lines, "\n"))
  -- While the AI functions are on: one line that names the review (nothing runs by itself).
  local ai_ok, ai_on = pcall(function()
    return require("tasks_nvim.ai").enabled()
  end)
  if ai_ok and ai_on then
    notify.info(("check it against its acceptance: :Tasks agent %s kind=review-done"):format(id))
  end
  if flow.steps_ticked > 0 then
    notify.info(
      ("%d plan step%s ticked off"):format(flow.steps_ticked, flow.steps_ticked == 1 and "" or "s")
    )
  end
  for _, doc in ipairs(flow.docs_refreshed) do
    notify.info("plan block refreshed in " .. doc)
  end
  for _, note in ipairs(flow.notes) do
    notify.warn(("%s: %s"):format(id, note))
  end
  M.after_finish(flow, id)
end

---Finish a task with the messages and the dialog of `:Tasks done` (without the confirmation: the caller asked).
---@param id string
---@param opts? { done_in?: string, commits?: string, date?: string }
function M.finish(id, opts)
  finish_task(id, opts or {})
end

---`:Tasks folderize <id>`
---@param ctx table
function M.task_folderize(ctx)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local before = scan.find(ctx.args.id)
  local res, err = mutate.folderize(ctx.args.id)
  if not res then
    notify.error(tostring(err))
    return
  end
  if not res.changed then
    notify.info(("%s is already a folder task"):format(res.id))
    return
  end
  if before then
    M.retarget_buffers(before.path, res.path)
  end
  if res.index_err then
    notify.warn("task moved, but the index was not updated: " .. res.index_err)
  end
  notify.info(("%s is now a folder task"):format(res.id))
end

---Put `text` at the cursor of the window that shows the file `path`, when there is one.
---@param path string
---@param text string
---@return boolean inserted
local function insert_at_cursor(path, text)
  local want = vim.fs.normalize(path)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if
      vim.bo[buf].buftype == ""
      and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == want
      and vim.bo[buf].modifiable
    then
      vim.api.nvim_win_call(win, function()
        vim.api.nvim_put({ text }, "c", true, true)
      end)
      return true
    end
  end
  return false
end

---Task id -> the number of its newest `:Tasks attach <id> from=clipboard`: an older one for the same task whose image
---comes later is dropped. The token belongs to the task: an attach to another task meanwhile is a wish of its own.
---@type table<string, integer>
local clipboard_attach_seq = {}

---Say what an attach did, and put its link where it can be pasted: at the cursor of the task when it is open in a
---window, else into the `+` register.
---@param res table  # the result of `mutate.attach` / `attach_source.attach`
---@param before? Tasks.Task  # the task as it was, to retarget buffers when it became a folder task
local function report_attach(res, before)
  if res.folderized and before then
    M.retarget_buffers(before.path, res.path)
  end
  if res.index_err then
    notify.warn("asset attached, but the index was not updated: " .. res.index_err)
  end
  if res.updated_err then
    notify.warn("asset attached, but `updated` was not changed: " .. res.updated_err)
  end
  if insert_at_cursor(res.path, res.link) then
    notify.info(("attached %s -> %s (link inserted at the cursor)"):format(res.id, res.rel))
    return
  end
  local copied = pcall(vim.fn.setreg, "+", res.link)
  notify.info(
    ("attached %s -> %s%s"):format(
      res.id,
      res.rel,
      copied and (" (link copied: " .. res.link .. ")") or (": " .. res.link)
    )
  )
end

---`:Tasks attach <id> <file> [name=<file name>] [kind=video|image|screenshot]`, or
---`:Tasks attach <id> from=clipboard|latest [dir=<folder>]`:
---copy the file (the clipboard image, the newest screenshot) into `assets/` (the folder of its kind below it:
---`assets/screenshots/` for the clipboard and the newest screenshot) and put the Markdown link at the
---cursor of the task when it is open in a window, else into the `+` register, and say so.
---
---`from=clipboard` does not wait for the clipboard program (on Windows a PowerShell start): the attach and its
---report follow when the image is there. A newer `from=clipboard` to the same task drops an older one still waiting
---(nothing of it is written), and the vault is the one of the call, also when it was switched meanwhile.
---@param ctx table
function M.task_attach(ctx)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local before = scan.find(ctx.args.id)
  local from = ctx.kv.from ~= "" and ctx.kv.from or nil
  local name = ctx.kv.name ~= "" and ctx.kv.name or nil
  local kind = ctx.kv.kind ~= "" and ctx.kv.kind or nil
  if kind ~= nil and not mutate.asset_dir(kind) then
    notify.error("kind= takes video, image or screenshot, got " .. kind)
    return
  end
  ---@param res table|nil
  ---@param err string|nil
  local function finish(res, err)
    if not res then
      -- The engine speaks CLI (`--name=`); here the same option is `name=<file name>`.
      notify.error((tostring(err):gsub("pass %-%-name=", "pass name=<file name>")))
      return
    end
    report_attach(res, before)
  end
  local res, err, too_old
  if from then
    if ctx.args.file and ctx.args.file ~= "" then
      notify.error("give a file or from=clipboard|latest, not both")
      return
    end
    if from ~= "clipboard" and from ~= "latest" then
      notify.error("from= takes clipboard or latest, got " .. from)
      return
    end
    if from == "clipboard" then
      local source = require("tasks_nvim.attach_source")
      local target = ctx.args.id
      local seq = (clipboard_attach_seq[target] or 0) + 1
      clipboard_attach_seq[target] = seq
      -- `M.attach_opts`: the seam of the specs (a fake clipboard, the vault).
      local base = M.attach_opts or {}
      source.attach_async(
        ctx.args.id,
        "clipboard",
        vim.tbl_extend("force", base, {
          name = name,
          kind = kind,
          root = base.root or vault.root(),
          cancelled = function()
            return seq ~= clipboard_attach_seq[target]
          end,
        }),
        function(cres, cerr)
          if cerr == source.CANCELLED then
            return
          end
          finish(cres, cerr)
        end
      )
      return
    end
    res, err, too_old = require("tasks_nvim.attach_source").attach(ctx.args.id, from, {
      name = name,
      kind = kind,
      dir = ctx.kv.dir ~= "" and ctx.kv.dir or nil,
    })
    if not res and too_old then
      err = tostring(err) .. " (give the file, or raise attach.max_age_s)"
    end
  elseif not ctx.args.file or ctx.args.file == "" then
    notify.error("give a file, or from=clipboard|latest")
    return
  else
    -- The composer's FILE type has resolved `~` and variables already (and checked the file is
    -- there). A second `vim.fn.expand` would read `[1]` in `shot[1].png` as a wildcard (attaching
    -- `shot1.png` instead) and run a backtick in a downloaded file's name through the shell.
    res, err = mutate.attach(
      ctx.args.id,
      vim.fn.fnamemodify(ctx.args.file, ":p"),
      { name = name, kind = kind }
    )
  end
  finish(res, err)
end

---Attach "a screenshot" to a task: the clipboard image, else the newest screenshot of the screenshot folders. The
---one entry the new-task form and the dashboard share with `:Tasks attach <id> from=...`: the same
---`attach_source`, the same report, no second way. With neither source there is one message that names both
---and nothing is attached (the task itself is not touched).
---@param id string  # `<area>/<slug>`
---@return table|nil res  # the result of `attach_source.attach`; nil: nothing attached
function M.attach_screenshot(id)
  local source = require("tasks_nvim.attach_source")
  -- `M.attach_opts`: the seam of the specs (a fake clipboard, a folder, the clock).
  local base = M.attach_opts or {}
  local before = scan.find(id)
  local res, clip_err = source.attach(id, "clipboard", base)
  local latest_err
  if not res then
    res, latest_err = source.attach(id, "latest", base)
  end
  if not res then
    notify.warn(
      ("no screenshot attached to %s: %s; %s"):format(id, tostring(clip_err), tostring(latest_err))
    )
    return nil
  end
  report_attach(res, before)
  return res
end

---`:Tasks done <id> [done_in=...] [commits=repo@sha,...] [date=YYYY-MM-DD] [outcome=seen reason=...] [--yes]`
---@param ctx table
function M.task_done(ctx)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local id = ctx.args.id
  local opts = {
    done_in = ctx.kv.done_in,
    commits = ctx.kv.commits,
    date = ctx.kv.date,
    remind = ctx.kv.remind,
    outcome = ctx.kv.outcome,
    outcome_reason = ctx.kv.reason,
    ci = ctx.kv.ci,
  }
  local task = scan.find(id)
  if not task or ctx.flags.yes then
    -- A finished task answers "already" without asking anything.
    finish_task(id, opts)
    return
  end
  local bucket = vault.BUCKET_OF_KIND[task.kind or "task"] or "?"
  local date = opts.date or model.today()
  confirm.yesno(
    ("Finish task %s?\n\n%s\n\nIt moves to Backlog/%s/%s_%s%s."):format(
      id,
      task.title,
      bucket,
      date,
      task.slug,
      task.folder and " (the whole folder)" or ".md"
    ),
    "finish",
    function(accepted)
      if not accepted then
        notify.info("cancelled -- the task stays open")
        return
      end
      finish_task(id, opts)
    end
  )
end

---The lines of `:Tasks milestones`: one per milestone, as `tasks milestones` says it (id, status, due, members done of
---all, overdue), the overdue ones first is the engine's order; a word when there are none.
---@param doc table  # `tasks.milestones`
---@return string[]
function M.milestone_lines(doc)
  local items = doc.items or {}
  if #items == 0 then
    return { "no milestones" }
  end
  local lines = {}
  for _, m in ipairs(items) do
    local p = m.progress or {}
    lines[#lines + 1] = ("%s  %s  due %s  %d/%d%s  %s"):format(
      m.id,
      m.status or "?",
      m.due or "-",
      p.members_done or 0,
      p.members or 0,
      m.overdue and "  overdue" or "",
      m.title or ""
    )
  end
  return lines
end

---`:Tasks milestones [area]`: the milestones in a float (`tasks.milestones` of the contract, as `tasks milestones`); the
---next key closes it.
---@param ctx table  composer context
function M.task_milestones(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local doc, err = require("tasks_nvim.contract").milestones(
    { area = ctx.args.area },
    { root = root }
  )
  if not doc then
    notify.error(tostring(type(err) == "table" and err.message or err))
    return
  end
  require("tasks_nvim.ui.help_float").open(M.milestone_lines(doc), "tasks_milestones")
end

---`:Tasks reopen <id> [status=open|doing|...] [--yes]`: a finished task back to `ROADMAP/tasks`, through the write door
---(`reopen` of `tasks-ops/1`, as the CLI's `tasks reopen`). Asks first, with the file it comes from; `--yes` skips the
---question. An open task is only named.
---@param ctx table  composer context
---@param confirm_fn? fun(msg: string, label: string, cb: fun(yes: boolean))  A stand-in for the dialog (specs).
function M.task_reopen(ctx, confirm_fn)
  if not no_stray_words(ctx) then
    return
  end
  local id, status = ctx.args.id, ctx.kv.status
  if status ~= nil and not model.is_open_status(status) then
    notify.error(
      ("unknown status '%s' (expected %s)"):format(status, table.concat(model.OPEN_STATUSES, ", "))
    )
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  if scan.find(id, { root = root }) then
    notify.info(("%s is open already"):format(id))
    return
  end
  local finished = scan.find_done(id, { root = root })
  if not finished then
    notify.error("no such finished task: " .. id)
    return
  end
  local function run()
    write_door_prewarm()
    local doc, err = require("tasks_nvim.ops").run(
      { ops = { { op = "reopen", id = id, status = status } } },
      { root = root }
    )
    if not doc then
      notify.error(tostring(type(err) == "table" and err.message or err))
      return
    end
    local entry = doc.results[1]
    if not entry.ok then
      notify.error(tostring(entry.error.message))
      return
    end
    require("tasks_nvim.ui.routes").reset_complete_cache()
    -- a window on the finished file follows it to its open place, as after `done`
    if entry.file then
      M.retarget_buffers(finished.path, root .. "/" .. entry.file)
    end
    for _, note in ipairs(entry.notes or {}) do
      notify.warn(note)
    end
    local lines = { ("reopened %s -> %s"):format(id, entry.file or "ROADMAP/tasks") }
    for _, m in ipairs(entry.milestones_reopened or {}) do
      lines[#lines + 1] = "milestone open again: " .. m
    end
    notify.info(table.concat(lines, "\n"))
  end
  if ctx.flags.yes then
    run()
    return
  end
  local ask = confirm_fn or confirm.yesno
  ask(
    ("Bring task %s back?\n\n%s\n\nIt moves from Backlog/ to ROADMAP/tasks as %s."):format(
      id,
      finished.title,
      status or "open"
    ),
    "reopen",
    function(yes)
      if yes then
        run()
      else
        notify.info("cancelled -- the task stays finished")
      end
    end
  )
end

-- ── plan-close / project-close ───────────────────────────────────────────────

---What holds a plan or a project open, in one line.
---@param res Tasks.CloseByHand
---@return string
local function holding_text(res)
  local n = #res.holding
  local s = n == 1 and "" or "s"
  local what = res.kind == "plan" and ("task" .. s) or ("task" .. s .. " or plan" .. s)
  return ("%s still has %d open %s: %s"):format(res.id, n, what, table.concat(res.holding, ", "))
end

---`:Tasks plan-close <id> [--yes]` / `:Tasks project-close <id> [--yes]`: finish a plan or a project that does not finish
---by itself (`done_flow.close_by_hand`, the CLI's verbs). The engine is asked first (a dry run): a refusal names what
---holds it open and nothing is asked; else a question, which `--yes` skips.
---@param ctx table
---@param kind "plan"|"project"
function M.close_by_hand(ctx, kind)
  if #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return
  end
  local plan_view = require("tasks_nvim.plan_view")
  local id = ctx.args.id
  local preview = done_flow.close_by_hand(kind, id, { dry_run = true })
  if preview.already then
    notify.info(("%s is already finished (%s)"):format(id, preview.already))
    return
  end
  if preview.holding then
    notify.error(holding_text(preview))
    return
  end
  if preview.err then
    notify.error(preview.err)
    return
  end
  local function run()
    local res = done_flow.close_by_hand(kind, id, { defer_stale_refs = true })
    for _, note in ipairs(res.notes) do
      notify.warn(note)
    end
    if res.holding then
      notify.error(holding_text(res))
      return
    end
    if res.err then
      notify.error(res.err)
      return
    end
    for _, plan_id in ipairs(res.plans_closed) do
      notify.info(plan_view.plan_closed_text(plan_id, res.plan_summaries[plan_id]))
    end
    for _, project_id in ipairs(res.projects.closed) do
      notify.info(plan_view.project_closed_text(project_id, res.projects.summaries[project_id]))
    end
    for _, note in ipairs(res.projects.notes) do
      notify.warn(note)
    end
  end
  if ctx.flags.yes then
    run()
    return
  end
  local file = (kind == "project" and require("tasks_nvim.projects") or require("tasks_nvim.plans")).find(
    id
  )
  confirm.yesno(
    ("Finish %s %s by hand?\n\n%s\n\nIt moves to Backlog/FEATURES/%s_%s.md."):format(
      kind,
      id,
      file and file.title or id,
      model.today(),
      file and file.slug or id
    ),
    "finish",
    function(accepted)
      if not accepted then
        notify.info(("cancelled -- the %s stays open"):format(kind))
        return
      end
      run()
    end
  )
end

-- ── task claim / unclaim ─────────────────────────────────────────────────────

---The file of an open task, to bring its buffers up to date after a claim set or took the status.
---@param id string
local function refresh_task_buffers(id)
  local task = scan.find(id)
  if task and task.path then
    refresh_buffers(task.path)
  end
end

---`:Tasks claim <id> [for=4h] [by=<name>] [note=<why>] [--renew] [--force]`: reserve a task while somebody works on it
---(`tasks_nvim.claims`, the verb the CLI has). Without `by=` the editor is `cdx:<session>` in a Claude Code session,
---else `<user>@<host>`.
---@param ctx table
function M.task_claim(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local id = ctx.args.id
  local res, err = claims.acquire(id, {
    by = ctx.kv.by,
    for_ = ctx.kv["for"],
    note = ctx.kv.note,
    renew = ctx.flags.renew == true,
    force = ctx.flags.force == true,
  })
  if not res then
    notify.error(tostring(err))
    return
  end
  if res.taken_over then
    notify.warn(
      ("took over the claim of %s (%s)"):format(res.taken_over.by, claims.describe(res.taken_over))
    )
  end
  refresh_task_buffers(id)
  notify.info(
    ("%s %s for %s until %s"):format(
      res.renewed and "renewed" or "claimed",
      id,
      res.claim.by,
      res.claim.until_
    )
  )
end

---`:Tasks unclaim <id> [by=<name>] [note=<why>] [status=open|parked|decision] [--force]`: give a task back (the status
---it goes back to: `open` unless said otherwise).
---@param ctx table
function M.task_unclaim(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local id = ctx.args.id
  local res, err = claims.release(id, {
    by = ctx.kv.by,
    note = ctx.kv.note,
    status = ctx.kv.status,
    force = ctx.flags.force == true,
  })
  if not res then
    notify.error(tostring(err))
    return
  end
  refresh_task_buffers(id)
  notify.info(("unclaimed %s: %s"):format(id, res.status or "-"))
end

-- ── task template / open ─────────────────────────────────────────────────────

---`:Tasks template [--to=clipboard|buffer|file:<path>]`
---@param ctx table
function M.task_template(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local target, terr = view.parse_target(ctx.flags.to or "clipboard")
  if terr or not target or target.kind == "qf" then
    notify.error(terr or "--to=qf makes no sense for the template")
    return
  end
  local text = mutate.template({ with_plan = ctx.flags["with-plan"] == true })
  unless_overwrite_refused(target, ctx.flags.force, function()
    local ok, err = harvest.emit(text, target.kind, {
      path = target.path,
      title = "tasks://task-template",
      filetype = "markdown",
    })
    if not ok then
      if target.kind == "clipboard" then
        harvest.sink.scratch(text, { title = "tasks://task-template", filetype = "markdown" })
        notify.warn(
          ("no clipboard (%s): the template is in a buffer instead"):format(tostring(err))
        )
        return
      end
      notify.error(tostring(err))
      return
    end
    if target.kind == "clipboard" then
      notify.info("task template copied to the + register")
    else
      notify.info("task template -> " .. target.kind)
    end
  end)
end

---Seam for the choice among several tasks (`nil`: `vim.ui.select`); specs replace it.
---@type (fun(items: Tasks.Match[], opts: table, cb: fun(choice: Tasks.Match|nil)))|nil
M.select_task = nil

---`:Tasks open <id|part>` -- an open task, else its finished copy in `Backlog/`. Anything but a full id is looked
---up by `tasks_nvim.match`: one hit is opened, several are offered, none is told (with the closest slugs).
---@param ctx table
function M.task_open(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local flags = ctx.flags or {}
  if flags.desktop or flags.web then
    return M.task_open_app(ctx, flags.desktop and "desktop" or "web")
  end
  local query = ctx.args.id
  if query == nil or query == "" then
    notify.error("open: give a task id (the id may be left out only with --desktop or --web)")
    return
  end
  local task, find_err = scan.find(query)
  task = task or scan.find_done(query)
  if task then
    open_file(task.path)
    return
  end
  if find_err and find_err:find("exists as", 1, true) then
    notify.error(find_err)
    return
  end
  local match = require("tasks_nvim.match")
  local found, near = match.match(query)
  local one = match.unique(found)
  local function open_id(id)
    local t = scan.find(id) or scan.find_done(id)
    if t then
      open_file(t.path)
    else
      notify.error("no such task: " .. id)
    end
  end
  if one then
    return open_id(one.id)
  end
  if #found == 0 then
    local _, vault_err = vault.root()
    -- a part of a name that comes close to some tasks offers them (a full id, or a missing vault, keeps its reason)
    if #near > 0 and not vault_err and not query:find("/", 1, true) then
      local items = {}
      for _, id in ipairs(near) do
        items[#items + 1] = { id = id }
      end
      local pick = M.select_task or vim.ui.select
      pick(items, {
        prompt = ("no task matches '%s'; did you mean> "):format(query),
        format_item = function(m)
          return m.id
        end,
      }, function(choice)
        if choice then
          open_id(choice.id)
        end
      end)
      return
    end
    local hint = #near > 0 and ("; did you mean " .. table.concat(near, ", ") .. "?") or ""
    -- a full id that is none keeps its reason ("no such open task"); a part of a name has none, unless the
    -- vault itself is missing: that is what to tell then
    local reason = (vault_err or query:find("/", 1, true)) and (vault_err or find_err)
      or ("no task matches '%s'"):format(query)
    notify.error(reason .. hint)
    return
  end
  local select = M.select_task or vim.ui.select
  select(found, {
    prompt = ("%d tasks match '%s'> "):format(#found, query),
    format_item = function(m)
      return m.id .. (m.done and "  [finished]" or "") .. (m.title and ("  " .. m.title) or "")
    end,
  }, function(choice)
    if choice then
      open_id(choice.id)
    end
  end)
end

---`:Tasks open [<id>] --desktop | --web`: the task alone in tasks-desktop or tasks-web (`tasks_nvim.open_app`).
---@param ctx table
---@param which "desktop"|"web"
function M.task_open_app(ctx, which)
  local app = require("tasks_nvim.open_app")
  if ctx.flags.desktop and ctx.flags.web then
    notify.error("open: --desktop and --web exclude each other")
    return
  end
  local id = ctx.args.id
  if id == nil or id == "" then
    id = app.default_id()
    if not id then
      notify.error("open: no id given, this buffer is no task and none was created in this session")
      return
    end
  else
    local task, find_err = scan.find(id)
    task = task or scan.find_done(id)
    if not task then
      notify.error(find_err or ("no such task: " .. id))
      return
    end
    id = task.id or id
  end
  local ok, msg = app.open(id, which)
  if ok then
    notify.info("opened " .. msg)
  else
    notify.error(msg)
  end
end

---`:Tasks preview <id>` -- the task file (an open one, else its finished
---copy) rendered in the browser by mdview.nvim; read-only for the vault.
---@param ctx table
function M.task_preview(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local id = ctx.args.id
  local task, find_err = scan.find(id)
  task = task or scan.find_done(id)
  if not task then
    notify.error(find_err or ("no such task: " .. id))
    return
  end
  local ok, err = require("tasks_nvim.ui.preview").open_file(task.path)
  if not ok then
    notify.warn(("cannot preview %s: %s"):format(id, tostring(err)))
    return
  end
  notify.info("previewing " .. id .. " in the browser")
end

-- ── open <area> <folder> ─────────────────────────────────────────────────────

---Markdown files below `dir`, relative to it, sorted.
---@param dir string
---@return string[]
local function markdown_below(dir)
  local out = {}
  for _, p in ipairs((require("lib.nvim.fs.collect_recursive").files(dir))) do
    local n = fsio.norm(p)
    if n:match("%.md$") then
      out[#out + 1] = n
    end
  end
  table.sort(out)
  return out
end

---The pickers.nvim engine and its dispatcher, when that plugin is installed.
---@return table|nil command  `pickers.command`
---@return table|nil engine
local function pickers_backend()
  local command = soft.check({ "dispatch" }, pcall(require, "pickers.command"))
  if not command then
    return nil, nil
  end
  local engines = soft.check({ "load" }, pcall(require, "pickers.engines"))
  if not engines then
    return nil, nil
  end
  local engine = engines.load()
  if not engine then
    return nil, nil
  end
  return command, engine
end

---@see pickers_backend
M.pickers_backend = pickers_backend

---`:Tasks folder <area> [folder] [--action=files|grep|smart] [--list] [--to=]`
---
---Opens a pickers.nvim picker whose search root is exactly that one folder of
---the area (`pickers.command.dispatch` with an explicit `roots` source, so
---the picker can be repeated). Without pickers.nvim it falls back to a
---`vim.ui.select` over the folder's `*.md` files -- no content search.
---`--list` (or `--to=`) delivers the file list instead of opening a picker.
---@param ctx table
function M.open_area(ctx)
  if not no_stray_words(ctx) then
    return
  end
  local root = vault_root()
  if not root then
    return
  end
  local area = ctx.args.area
  local folder = ctx.args.folder or "all"
  local sub = M.FOLDERS[folder]
  if sub == nil then
    notify.error(
      ("unknown folder '%s' (expected %s)"):format(
        folder,
        "tasks|roadmap|backlog|handover|notes|all"
      )
    )
    return
  end
  local dir = root .. "/" .. area .. (sub ~= "" and ("/" .. sub) or "")
  if not fsio.is_dir(dir) then
    notify.warn(("%s has no %s folder (%s)"):format(area, folder, rel(dir, root)))
    return
  end

  local target, terr = view.parse_target(ctx.flags.to)
  if terr or (target and target.kind == "qf") then
    notify.error(terr or "--to=qf is not supported for :Tasks folder")
    return
  end

  if ctx.flags.list or target then
    local lines = {}
    for _, p in ipairs(markdown_below(dir)) do
      lines[#lines + 1] = p:sub(#dir + 2)
    end
    if #lines == 0 then
      notify.info(("no Markdown file in %s"):format(rel(dir, root)))
      return
    end
    local kind = target and target.kind or "buffer"
    unless_overwrite_refused(target, ctx.flags.force, function()
      local ok, err = harvest.emit(table.concat(lines, "\n") .. "\n", kind, {
        path = target and target.path or nil,
        title = ("tasks://open/%s/%s"):format(area, folder),
        filetype = "text",
      })
      if not ok then
        notify.error(tostring(err))
      end
    end)
    return
  end

  local action = ctx.flags.action or "files"
  local command, engine = pickers_backend()
  if command then
    command.dispatch(action, {
      roots = { dir },
      prompt = ("%s/%s> "):format(area, folder),
    }, engine)
    return
  end

  if action ~= "files" then
    notify.warn(
      "pickers.nvim is not available: --action=" .. action .. " needs it, listing files instead"
    )
  end
  local files = markdown_below(dir)
  if #files == 0 then
    notify.info(("no Markdown file in %s"):format(rel(dir, root)))
    return
  end
  harvest.sink.select(files, {
    prompt = ("%s/%s"):format(area, folder),
    format = function(p)
      return p:sub(#dir + 2)
    end,
  }, function(path)
    open_file(path)
  end)
end

---The scratch buffer `tasks://<what>/<id>` with `lines` (a second call for the same task takes the same buffer).
---@param id string
---@param lines string[]
---@param what? string `agent` (default) or `review`
---@return integer buf
local function agent_buffer(id, lines, what)
  local name = ("tasks://%s/%s"):format(what or "agent", id)
  local buf = -1
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      buf = b
    end
  end
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("botright sbuffer " .. buf)
    end
  else
    vim.cmd("botright new")
    buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

---Without ai-desktop: the task as one prompt for ai.nvim, in a scratch buffer; `run` sends it after a question and
---puts the answer below it (one answer, no tools, nothing written but the buffer).
---@param ai_nvim table
---@param payload table
---@param confirm_fn fun(msg: string, label: string, cb: fun(yes: boolean))
local function agent_ai_nvim(ai_nvim, payload, confirm_fn)
  local prompt = require("tasks_nvim.agent").prompt(payload)
  local buf = agent_buffer(payload.task_id, vim.split(prompt, "\n", { plain = true }))
  if payload.mode ~= "run" then
    notify.info(
      ("agent: the prompt for %s is in this buffer; :Tasks agent %s mode=run sends it to ai.nvim"):format(
        payload.task_id,
        payload.task_id
      )
    )
    return
  end
  confirm_fn(
    ("Send the task %s (%d characters) to ai.nvim?"):format(payload.task_id, #prompt),
    "send",
    function(yes)
      if not yes then
        return
      end
      notify.info("agent: waiting for the answer of ai.nvim ...")
      ai_nvim.ask({ prompt = prompt, context = {} }, function(ok, res)
        vim.schedule(function()
          if not ok then
            local why = type(res) == "table" and res.message or tostring(res)
            notify.error("agent: ai.nvim: " .. tostring(why))
          elseif not vim.api.nvim_buf_is_valid(buf) then
            notify.warn("agent: the buffer of the task is gone, the answer with it")
          else
            local answer = vim.split(tostring(type(res) == "table" and res.text or ""), "\r?\n")
            vim.api.nvim_buf_set_lines(
              buf,
              -1,
              -1,
              false,
              vim.list_extend({ "", "<!-- the answer of ai.nvim -->", "" }, answer)
            )
            notify.info("agent: ai.nvim answered " .. payload.task_id)
          end
        end)
      end)
    end
  )
end

---The review of a finished task came back (`kind=review-done`): show its block, add it to the task as a section after
---a yes, and create the follow-up task it proposes after a second yes. Nothing is written without them.
---@param task table The task as `scan.find` / `scan.find_done` gave it.
---@param job table The job of ai-desktop (`GET /jobs/<id>`).
---@param confirm_fn fun(msg: string, label: string, cb: fun(yes: boolean))
---@param create? fun(area: string, opts: table): table|nil, string|nil A stand-in for `mutate.new` (specs).
local function review_came_back(task, job, confirm_fn, create)
  local review = require("tasks_nvim.review")
  if job.status ~= "done" then
    notify.error(
      ("agent: the review of %s ended %s%s"):format(
        task.id,
        tostring(job.status),
        type(job.error) == "string" and (": " .. job.error) or ""
      )
    )
    return
  end
  local block = review.block(type(job.output) == "string" and job.output or "")
  local good, why = false, "the answer has no review block"
  if block then
    good, why = review.check(block)
  end
  if not good then
    notify.warn(
      ("agent: %s; the answer is in the dashboard of ai-desktop (job %s)"):format(why, job.id)
    )
    return
  end
  agent_buffer(task.id, vim.split(block, "\n", { plain = true }), "review")
  local heading = block:match("^[^\n]*")
  confirm_fn(
    ("Add this review to %s as its section %s?"):format(task.id, heading),
    "add",
    function(yes)
      if not yes then
        notify.info("agent: the review was not added; it stays in this buffer")
        return
      end
      write_door_prewarm()
      local ok, err = review.adopt(task.id, block)
      if not ok then
        notify.error("agent: " .. tostring(err))
        return
      end
      pcall(vim.cmd, "checktime")
      notify.info(("agent: the review is in %s (%s)"):format(task.id, heading))
      local follow = review.follow_up(block)
      if not follow then
        return
      end
      confirm_fn(
        ("The review proposes a follow-up task in %s:\n\n%s\n\nCreate it?"):format(
          task.area,
          follow.title
        ),
        "create",
        function(again)
          if not again then
            return
          end
          local made, merr = (create or require("tasks_nvim.mutate").new)(task.area, {
            title = follow.title,
            summary = follow.summary,
            kind = "task",
          })
          if not made then
            notify.error("agent: the follow-up task was not created: " .. tostring(merr))
            return
          end
          notify.info("agent: created " .. tostring(made.id))
        end
      )
    end
  )
end

---A prepared decision came back (`kind=prepare-decision`): show it, and after a yes write the proposal (and the open
---questions, when the task has none of its own) into the task through the engine (`mutate.edit_text`); the status
---stays `decision`, the person answers the questions (`:Tasks answer`).
---@param task table The open task as `scan.find` gave it.
---@param job table The job of ai-desktop.
---@param confirm_fn fun(msg: string, label: string, cb: fun(yes: boolean))
local function decision_came_back(task, job, confirm_fn)
  local review = require("tasks_nvim.review")
  if job.status ~= "done" then
    notify.error(
      ("agent: the preparation of %s ended %s%s"):format(
        task.id,
        tostring(job.status),
        type(job.error) == "string" and (": " .. job.error) or ""
      )
    )
    return
  end
  local block = review.block(type(job.output) == "string" and job.output or "", "decision")
  local parts, why = nil, "the answer has no decision block"
  if block then
    parts, why = review.check_decision(block)
  end
  if not parts or not block then
    notify.warn(
      ("agent: %s; the answer is in the dashboard of ai-desktop (job %s)"):format(why, job.id)
    )
    return
  end
  agent_buffer(task.id, vim.split(block, "\n", { plain = true }), "decision")
  confirm_fn(
    ("Add this proposal to %s%s? The task stays a decision; you decide."):format(
      task.id,
      parts.questions and " (with its open questions)" or ""
    ),
    "add",
    function(yes)
      if not yes then
        notify.info("agent: the proposal was not added; it stays in this buffer")
        return
      end
      local blocks, added = review.decision_blocks(fsio.read(task.path) or "", parts)
      write_door_prewarm()
      local wrote, err = review.write(task.id, blocks)
      if not wrote then
        notify.error("agent: " .. tostring(err))
        return
      end
      refresh_task_buffers(task.id)
      notify.info(("agent: the proposal is in %s"):format(task.id))
      if parts.questions and added then
        notify.info(
          ("agent: answer its questions with :Tasks answer %s <question> <option>"):format(task.id)
        )
      elseif parts.questions then
        notify.info(
          "agent: the task has open questions of its own; they stay, the proposal's are only in its text"
        )
      end
    end
  )
end

---The plan of the current buffer (its file is a plan file), or nil.
---@return string|nil
local function buffer_plan_id()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return nil
  end
  local want = vim.fn.fnamemodify(name, ":p")
  for _, plan in ipairs(require("tasks_nvim.plans").all() or {}) do
    if plan.path and fsio.same_path(plan.path, want) then
      return plan.id
    end
  end
  return nil
end

---The text a split of `plan` sends: the plan file and the list of its tasks, open and finished, so that the drafts do
---not repeat them (also for a model that cannot read the vault).
---@param plan table A plan file (`plans.find`).
---@param text string The plan file.
---@return string
local function split_markdown(plan, text)
  local lines = {}
  local function add(t, state)
    lines[#lines + 1] = ("- %s (%s, phase %s): %s"):format(
      t.id,
      state,
      t.phase or "-",
      t.title or ""
    )
  end
  for _, t in ipairs(require("tasks_nvim.plans").members(plan.id, scan.all() or {})) do
    add(t, t.status or "open")
  end
  local areas = { plan.area }
  for _, a in ipairs(plan.areas or {}) do
    if not vim.tbl_contains(areas, a) then
      areas[#areas + 1] = a
    end
  end
  for _, area in ipairs(areas) do
    for _, t in ipairs(scan.backlog(area) or {}) do
      if t.plan == plan.id then
        add(t, "done")
      end
    end
  end
  table.sort(lines)
  return vim.trim(text)
    .. "\n\n## Tasks of this plan\n\n"
    .. (#lines > 0 and table.concat(lines, "\n") or "(none yet)")
    .. "\n"
end

---The body of a task created from a draft: where it came from and its acceptance, in the language of the plan.
---@param draft Tasks.SplitDraft
---@param plan_id string
---@param job_id string
---@param german boolean
---@return string
local function draft_body(draft, plan_id, job_id, german)
  local lines = {}
  if german then
    lines[#lines + 1] = "## Kontext"
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Entwurf aus der Zerlegung des Plans `%s` (ai-desktop, Auftrag %s)."):format(
      plan_id,
      job_id
    )
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Akzeptanz"
  else
    lines[#lines + 1] = "## Context"
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("A draft of the split of the plan `%s` (ai-desktop, job %s)."):format(
      plan_id,
      job_id
    )
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Acceptance"
  end
  lines[#lines + 1] = ""
  for _, a in ipairs(draft.acceptance) do
    lines[#lines + 1] = "- [ ] " .. a
  end
  if #draft.acceptance == 0 then
    lines[#lines + 1] = "- [ ] "
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = german and "## Notizen" or "## Notes"
  return table.concat(lines, "\n") .. "\n"
end

---The lines of the split buffer: one box per draft, what it would be, why one cannot be created.
---@param plan_id string
---@param job_id string
---@param parsed { phases: table[], drafts: Tasks.SplitDraft[] }
---@return string[]
local function split_lines(plan_id, job_id, parsed)
  local lines = {
    ("# Split of the plan %s (ai-desktop job %s)"):format(plan_id, job_id),
    "",
    "Tick the drafts to create ([x]), then :w. Nothing is created before a yes; a new phase is asked for on its own.",
    "",
  }
  local names = {}
  for _, p in ipairs(parsed.phases) do
    names[#names + 1] = p.name .. (p.new and " (new)" or "")
  end
  if #names > 0 then
    lines[#lines + 1] = "Phases: " .. table.concat(names, ", ")
    lines[#lines + 1] = ""
  end
  for _, d in ipairs(parsed.drafts) do
    if d.invalid then
      lines[#lines + 1] = ("- [-] %d. %s  (cannot be created: %s)"):format(d.n, d.title, d.invalid)
    else
      lines[#lines + 1] = ("- [ ] %d. %s"):format(d.n, d.title)
    end
    local facts = { "area " .. d.area }
    for _, key in ipairs({ "kind", "prio", "effort", "value", "phase" }) do
      if d[key] ~= nil then
        facts[#facts + 1] = key .. " " .. tostring(d[key])
      end
    end
    lines[#lines + 1] = "      " .. table.concat(facts, " · ")
    if d.summary then
      lines[#lines + 1] = "      " .. d.summary
    end
    if #d.acceptance > 0 then
      lines[#lines + 1] = "      acceptance: " .. table.concat(d.acceptance, "; ")
    end
    if #d.after > 0 or #d.blocked_by > 0 then
      lines[#lines + 1] = ("      after: %s · blocked_by: %s"):format(
        #d.after > 0 and table.concat(d.after, ", ") or "-",
        #d.blocked_by > 0 and table.concat(d.blocked_by, ", ") or "-"
      )
    end
  end
  return lines
end

---Creates the ticked drafts of a split buffer after a yes (and a new phase only after its own yes), through the
---engine; a draft that the engine refuses is refused alone, with the reason, in the buffer and in a message.
---@param buf integer
---@param confirm_fn fun(msg: string, label: string, cb: fun(yes: boolean))
---@param deps table `create` (mutate.new), `set` (mutate.set), `plan_set` (plans.set): stand-ins for the specs.
local function split_create(buf, confirm_fn, deps)
  local state = vim.b[buf].tasks_split
  if not state then
    return
  end
  local plans = require("tasks_nvim.plans")
  local ticked = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local n = line:match("^%- %[[xX]%] (%d+)%.")
    if n then
      ticked[#ticked + 1] = tonumber(n)
    end
  end
  vim.bo[buf].modified = false
  if #ticked == 0 then
    notify.info("agent: nothing ticked, nothing created")
    return
  end
  table.sort(ticked)
  local plan = plans.find(state.plan)
  if not plan then
    notify.error("agent: the plan " .. state.plan .. " is gone")
    return
  end
  local drafts = state.drafts
  local new_phases = {}
  for _, n in ipairs(ticked) do
    local d = drafts[n]
    if
      d
      and not d.invalid
      and d.phase
      and not vim.tbl_contains(plan.phase_order or {}, d.phase)
      and not vim.tbl_contains(new_phases, d.phase)
    then
      new_phases[#new_phases + 1] = d.phase
    end
  end
  local function create_all(phases_ok)
    local created, refused = {}, {}
    local made_ids = {}
    local function draft_ids(list, n, what)
      local out = {}
      for _, ref in ipairs(list) do
        local k = ref:match("^#(%d+)$")
        if k then
          local id = made_ids[tonumber(k)]
          if id then
            out[#out + 1] = id
          else
            refused[#refused + 1] = ("draft %d: its %s #%s was not created, left out"):format(
              n,
              what,
              k
            )
          end
        else
          out[#out + 1] = ref
        end
      end
      return out
    end
    for _, n in ipairs(ticked) do
      local d = drafts[n]
      if not d then
        refused[#refused + 1] = ("draft %d: there is no such draft"):format(n)
      elseif d.invalid then
        refused[#refused + 1] = ("draft %d (%s): %s"):format(n, d.title, d.invalid)
      elseif d.phase and not phases_ok and vim.tbl_contains(new_phases, d.phase) then
        refused[#refused + 1] = ("draft %d (%s): its phase %s is not in the plan"):format(
          n,
          d.title,
          d.phase
        )
      else
        local after = draft_ids(d.after, n, "after")
        local res, err = (deps.create or mutate.new)(d.area, {
          title = d.title,
          kind = d.kind,
          prio = d.prio,
          effort = d.effort,
          value = d.value,
          plan = state.plan,
          phase = d.phase,
          summary = d.summary,
          after = #after > 0 and after or nil,
          body = draft_body(d, state.plan, state.job, state.german),
        })
        if not res then
          refused[#refused + 1] = ("draft %d (%s): %s"):format(n, d.title, tostring(err))
        else
          made_ids[n] = res.id
          created[#created + 1] = res.id
          local blocked = draft_ids(d.blocked_by, n, "blocked_by")
          if #blocked > 0 then
            local ok, serr = (deps.set or mutate.set)(res.id, { blocked_by = blocked })
            if not ok then
              refused[#refused + 1] = ("draft %d: created as %s, but its blocked_by was refused: %s"):format(
                n,
                res.id,
                tostring(serr)
              )
            end
          end
        end
      end
    end
    -- What became of each ticked draft, in the buffer too.
    if vim.api.nvim_buf_is_valid(buf) then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for i, line in ipairs(lines) do
        local n = tonumber(line:match("^%- %[[xX]%] (%d+)%."))
        if n and made_ids[n] then
          lines[i] = line:gsub("^%- %[[xX]%]", "- [+]", 1) .. "  -> " .. made_ids[n]
        elseif n then
          lines[i] = line:gsub("^%- %[[xX]%]", "- [!]", 1) .. "  (refused, see the message)"
        end
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modified = false
    end
    if #created > 0 then
      notify.info("agent: created " .. table.concat(created, ", "))
    end
    for _, why in ipairs(refused) do
      notify.warn("agent: " .. why)
    end
  end
  confirm_fn(
    ("Create %d task(s) in the plan %s?"):format(#ticked, state.plan),
    "create",
    function(yes)
      if not yes then
        notify.info("agent: nothing created")
        return
      end
      if #new_phases == 0 then
        create_all(true)
        return
      end
      confirm_fn(
        ("The drafts name phase(s) the plan %s does not have: %s. Add them to its phase_order?"):format(
          state.plan,
          table.concat(new_phases, ", ")
        ),
        "add",
        function(add)
          if add then
            local order = vim.deepcopy(plan.phase_order or {})
            vim.list_extend(order, new_phases)
            local ok, perr = (deps.plan_set or plans.set)(state.plan, { phase_order = order })
            if not ok then
              notify.error("agent: the phases were not added: " .. tostring(perr))
              create_all(false)
              return
            end
          end
          create_all(add)
        end
      )
    end
  )
end

---A split came back (`kind=split-plan`): the drafts go into `tasks://split/<plan>` to tick; `:w` there creates the
---ticked ones after a yes (`split_create`).
---@param plan table The plan file.
---@param job table The job of ai-desktop.
---@param confirm_fn fun(msg: string, label: string, cb: fun(yes: boolean))
---@param deps table
local function split_came_back(plan, job, confirm_fn, deps)
  local review = require("tasks_nvim.review")
  if job.status ~= "done" then
    notify.error(
      ("agent: the split of %s ended %s%s"):format(
        plan.id,
        tostring(job.status),
        type(job.error) == "string" and (": " .. job.error) or ""
      )
    )
    return
  end
  local block = review.block(type(job.output) == "string" and job.output or "", "split")
  local parsed, why = nil, "the answer has no split block"
  if block then
    parsed, why = review.parse_split(block)
  end
  if not parsed then
    notify.warn(
      ("agent: %s; the answer is in the dashboard of ai-desktop (job %s)"):format(why, job.id)
    )
    return
  end
  local buf = agent_buffer(plan.id, split_lines(plan.id, job.id, parsed), "split")
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].modified = false
  local text = fsio.read(plan.path) or ""
  vim.b[buf].tasks_split = {
    plan = plan.id,
    job = job.id,
    drafts = parsed.drafts,
    german = text:find("## Ziel", 1, true) ~= nil or text:find("## Leitlinien", 1, true) ~= nil,
  }
  local group = vim.api.nvim_create_augroup("tasks_split_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      split_create(buf, confirm_fn, deps)
    end,
  })
  notify.info(
    ("agent: %d draft(s) for %s; tick the ones to create, then :w"):format(#parsed.drafts, plan.id)
  )
end

local AGENT_SAID = {
  prefilled = "it waits in the dashboard of ai-desktop, nothing runs",
  running = "ai-desktop runs it",
  needs_confirmation = "ai-desktop asks first (a private area)",
}

---`:Tasks agent [<id>] [mode=prefill|run] [kind=handoff|...]`: hand the task (the named one, else the buffer's) to
---ai-desktop's job intake (`tasks_nvim.agent`), or, without a running ai-desktop, to ai.nvim for one answer. Hidden
---while the AI functions are off (`setup({ ai = ... })`, `tasks_nvim.ai`).
---@param ctx table
---With `kind=review-done` the task may be finished (it is read from `Backlog/`), `mode` is `run` unless said, and the
---review's answer comes back here: shown, and added to the task as a section only after a yes.
---@param deps? table Stand-ins for the specs: `state`, `ai_desktop`, `hand_over`, `confirm`, `record`, `watch`, `create`.
function M.task_agent(ctx, deps)
  deps = deps or {}
  if not no_stray_words(ctx) then
    return
  end
  local ai = require("tasks_nvim.ai")
  local agent = require("tasks_nvim.agent")
  local state = deps.state or ai.state()
  if not state.on then
    notify.error(
      state.setting == false and "agent: the AI functions are off (setup({ ai = false }))"
        or "agent: neither ai-desktop nor ai.nvim is found on this machine"
    )
    return
  end
  local kv = ctx.kv or {}
  local kind = kv.kind or "handoff"
  local is_review = kind == "review-done"
  local is_decision = kind == "prepare-decision"
  local is_split = kind == "split-plan"
  -- A review, a prepared decision or a split is asked for to read its answer: it runs unless said otherwise.
  local mode = kv.mode or ((is_review or is_decision or is_split) and "run" or "prefill")
  if not vim.tbl_contains(agent.MODES, mode) then
    notify.error("agent: mode is prefill or run, not " .. tostring(mode))
    return
  end
  if not vim.tbl_contains(agent.KINDS, kind) then
    notify.error(
      "agent: kind is one of " .. table.concat(agent.KINDS, ", ") .. ", not " .. tostring(kind)
    )
    return
  end
  local id = (ctx.args or {}).id or (is_split and buffer_plan_id() or buffer_task_id())
  if not id or not id:match("^[%w_][^/]*/[^/]+$") then
    notify.error(
      is_split and "agent: name a plan (area/slug), or run it from a plan's buffer"
        or "agent: name a task (area/slug), or run it from a task's buffer"
    )
    return
  end
  local root, rerr = require("tasks_nvim.vault").root()
  if not root then
    notify.error("agent: " .. tostring(rerr))
    return
  end
  local task, payload
  if is_split then
    local plan, perr = require("tasks_nvim.plans").find(id)
    if not plan then
      notify.error("agent: split-plan names a plan: " .. tostring(perr))
      return
    end
    local text = fsio.read(plan.path)
    if not text then
      notify.error("agent: cannot read " .. tostring(plan.path))
      return
    end
    task = plan
    payload = agent.payload(
      { id = plan.id, title = plan.title, area = plan.area },
      root,
      split_markdown(plan, text),
      mode,
      kind
    )
  end
  local ferr
  if not task then
    task, ferr = scan.find(id)
  end
  if not task then
    local done = scan.find_done(id)
    if done and not is_review then
      notify.error(
        ("agent: %s is finished; a finished task is only reviewed (kind=review-done)"):format(id)
      )
      return
    end
    task = done
  end
  if not task then
    if require("tasks_nvim.plans").find(id) then
      notify.error(("agent: %s is a plan; a plan is only split (kind=split-plan)"):format(id))
      return
    end
    notify.error("agent: " .. tostring(ferr))
    return
  end
  if is_decision and task.status ~= "decision" then
    notify.error(
      ("agent: prepare-decision is for a task that waits for a decision (status decision); %s is %s"):format(
        id,
        tostring(task.status)
      )
    )
    return
  end
  if not payload then
    local file = task.path and io.open(task.path, "rb")
    if not file then
      notify.error("agent: cannot read " .. tostring(task.path))
      return
    end
    local markdown = file:read("*a") or ""
    file:close()
    payload = agent.payload(task, root, markdown, mode, kind)
  end

  local desktop = deps.ai_desktop or ai.ai_desktop()
  if desktop.running then
    notify.info("agent: handing " .. id .. " to ai-desktop ...")
    local hand_over = deps.hand_over or agent.hand_over
    hand_over(payload, function(herr, res)
      if herr or not res then
        notify.error("agent: " .. (herr or "no answer"))
        return
      end
      notify.info(
        ("agent: %s is with ai-desktop (job %s): %s%s"):format(
          id,
          res.job_id,
          AGENT_SAID[res.status] or res.status,
          res.note and (" (" .. res.note .. ")") or ""
        )
      )
      if not is_review and not is_decision and not is_split then
        return
      end
      -- The answer comes back to this editor (watched until the job ends).
      local record = res.peer or deps.record or ai.hub_record()
      if not record then
        notify.warn("agent: ai-desktop is gone; the review's answer is in its dashboard")
        return
      end
      local watch = deps.watch or agent.watch
      watch(record.port, res.job_id, function(werr, job)
        if werr or not job then
          notify.error("agent: " .. tostring(werr))
          return
        end
        local confirm_fn = deps.confirm
          or function(msg, label, cb)
            require("tasks_nvim.ui.confirm").yesno(msg, label, cb)
          end
        if is_split then
          split_came_back(task, job, confirm_fn, deps)
        elseif is_decision then
          decision_came_back(task, job, confirm_fn)
        else
          review_came_back(task, job, confirm_fn, deps.create)
        end
      end)
    end)
    return
  end
  if is_review or is_decision or is_split then
    -- These kinds read commits, repositories and the plan's tasks: ai-desktop's, not one answer of ai.nvim.
    notify.error(
      desktop.installed
          and "agent: ai-desktop is installed but not running; this kind needs it (it reads commits and repositories): start it"
        or "agent: this kind needs ai-desktop (it reads commits and repositories); it is not on this machine"
    )
    return
  end
  local has_ai, ai_nvim = pcall(require, "ai")
  if has_ai and type(ai_nvim) == "table" and type(ai_nvim.ask) == "function" then
    -- UI-03: a fallback says so.
    notify.warn(
      desktop.installed
          and "agent: ai-desktop is installed but not running; ai.nvim answers once instead"
        or "agent: no ai-desktop on this machine; ai.nvim answers once instead"
    )
    agent_ai_nvim(ai_nvim, payload, deps.confirm or function(msg, label, cb)
      require("tasks_nvim.ui.confirm").yesno(msg, label, cb)
    end)
    return
  end
  notify.error(
    desktop.installed
        and "agent: ai-desktop is installed but not running: start it, then :Tasks agent again"
      or "agent: there is no ai-desktop and no ai.nvim to hand the task to"
  )
end

return M
