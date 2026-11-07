---@module 'tasks_nvim.done_flow'
---@brief The one entry for "finish a task": `mutate.done` plus whatever follows from it.
---@description
--- Every front end that finishes a task (the `:Tasks done` command, the dashboard's `D`, the headless CLI) calls
--- `run` and nothing else. The flow is `mutate.done` and then the chain:
---  a. the open steps of the task's own `## Plan` are ticked (written WITH the finish, so its rollback covers them;
---     a step marked `(dropped)` stays open);
---  b. a plan file whose last member task this was is finished (moved to `Backlog/FEATURES/`);
---  c. the marker blocks (`<!-- GENERATED:plan scope=... -->`) of the documents named in `setup({ chain = {
---     marker_docs = {...} } })` are refreshed -- only those files, nothing is scanned;
---  d. the tasks the finish freed, and e. the next task to start (`next_pick`).
---
--- Before the chain, a routine (`repeat: 8w`) starts its next round: a new open task, the same fields and body (steps
--- and acceptance boxes ticked off again), `due` and `remind` set to the next date, and the slug `<base>-<due>`
--- (`sweep` becomes `sweep-2027-01-05`: an open task and a finished one may not share an id, `check` says
--- `duplicate-id`, so each round has an id of its own)
--- (`model.next_round_due`); `opts.last` finishes a routine without one. It is written after the finish and reported in
--- `next_round`; if it cannot be written the finish stands and a note says so (a routine must not be lost silently).
---
--- Rules the chain keeps (so they can be relied on now):
---  - the truth changes first: `mutate.done` runs, and only a successful, non-`already` finish starts the chain;
---  - a failure AFTER the finish never undoes it: it goes to `notes` (the task is done, one follow-up step did not
---    work -- an honest report, not a half rollback);
---  - an already finished task changes nothing and runs no chain.
---
--- Not its job: the finish itself (`mutate.done`), batches (`batch.done_many` calls `run` per task), messages.

local fm = require("lib.nvim.markdown.frontmatter")

local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local next_pick = require("tasks_nvim.next_pick")
local plan_scope = require("tasks_nvim.plan_scope")
local plans = require("tasks_nvim.plans")
local projects = require("tasks_nvim.projects")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---@class Tasks.DoneFlowOpts : Tasks.DoneOpts
---@field chain? boolean       # Run the follow-up steps (default true).
---@field pick_next? boolean   # Name the freed tasks and pick the next one (default true; a batch picks once at its end).
---@field refresh_docs? boolean  # Refresh the generated blocks of the configured documents (default true; a batch does it once).
---@field last? boolean        # Finish a routine (`repeat`) for good: no next round.
---@field defer_plan_close? boolean  # Leave step b to the caller (`close_plans`): a batch checks each plan once, not per task.

---What a finish did. `done` is what `mutate.done` returned (`done.already` for a task that was finished before).
---@class Tasks.DoneFlow
---@field done table                 # The result of `mutate.done`.
---@field steps_ticked integer       # Plan steps of the task ticked off.
---@field plan_summaries table<string, Tasks.PlanSummary>  # What each closed plan amounted to.
---@field freed string[]             # Ids of tasks whose last open blocker this was (set with `next`).
---@field plans_closed string[]      # Ids of plan files closed because their last member is done.
---@field projects_closed string[]   # Ids of project files closed because their last plan and own task is done (a parked plan does not hold a project open).
---@field project_summaries table<string, Tasks.ProjectSummary>  # What each closed project amounted to.
---@field docs_refreshed string[]    # Generated plan blocks that were refreshed.
---@field next_round? { id: string, due: string, path: string }  # The next round of a routine that was started.
---@field notes string[]             # Follow-up steps that did not work; the finish itself stands.
---@field next? Tasks.NextPick       # What to start next (`next_pick`); absent when not asked for or not computable.

---The documents whose marker blocks a finish refreshes: `setup({ chain = { marker_docs } })` plus `$TASKS_MARKER_DOCS`
---(comma separated; the headless CLI has no `setup`, so this is how it learns them, as `$TASKS_EXTRA_AREAS` is).
---Each file once, however it is spelled.
---@return string[]
function M.marker_docs()
  local out, seen = {}, {}
  ---@param doc any
  local function add(doc)
    if type(doc) ~= "string" or fsio.trim(doc) == "" then
      return
    end
    local key = fsio.doc_path(fsio.trim(doc))
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = key
    end
  end
  for _, doc in ipairs(require("tasks_nvim.config").get().chain.marker_docs) do
    add(doc)
  end
  local env = vim.env.TASKS_MARKER_DOCS
  if env and env ~= "" then
    for doc in env:gmatch("[^,]+") do
      add(doc)
    end
  end
  return out
end

---Refresh the marker blocks of the documents named in `setup({ chain = { marker_docs = ... } })` (and in
---`$TASKS_MARKER_DOCS`, which is how the headless CLI is told). Only those files
---are read or written; a block that cannot be refreshed is a note, never an error.
---`opts.closed` (plan id -> summary) names plans that were finished a moment ago: their block (the one that names the
---plan by `plan=<id>`, by id, or by a slug no open plan shares) is rewritten as the "plan is done" line, its last
---state.
---@param opts? { root?: string, closed?: table<string, table> }
---@return string[] refreshed  # The documents that changed.
---@return string[] notes
function M.refresh_marker_docs(opts)
  opts = opts or {}
  local refreshed, notes = {}, {}
  local docs = M.marker_docs()
  if #docs == 0 then
    return refreshed, notes
  end
  local root = vault.root(opts)
  if not root then
    return refreshed, notes
  end
  local closed
  for plan_id, summary in pairs(opts.closed or {}) do
    closed = closed or {}
    closed[plan_id] = require("tasks_nvim.plan_view").plan_closed_text(plan_id, summary)
  end
  for _, doc in ipairs(docs) do
    local path = fsio.doc_path(doc)
    local res, err = plan_scope.refresh_document(path, root, closed)
    if not res then
      notes[#notes + 1] = tostring(err)
    else
      if res.changed then
        refreshed[#refreshed + 1] = path
      end
      for _, skipped in ipairs(res.skipped) do
        notes[#notes + 1] = ("%s: %s"):format(path, skipped.reason)
      end
    end
  end
  return refreshed, notes
end

---@class Tasks.ClosedPlans
---@field closed string[]                        # Ids of the plan files that were finished.
---@field projects table<string, string>         # Closed plan id -> the project it belonged to (to judge the project next).
---@field refused table<string, string[]>        # Plan id -> the open tasks that hold it open.
---@field summaries table<string, Tasks.PlanSummary>
---@field notes string[]                         # Plans that could not be closed, or whose state could not be judged.

---Step b: finish every plan of `plan_ids` that has no open member task left. One scan for all of them, and none when
---no such plan file exists (a task may name a plan that was never written). A member is any task with `plan: <id>`
---whose status is not `done`, valid or not: a typo in `status:` must not make the plan look finished. A scan that
---could not list every folder cannot say that no member is open: the plans stay and a note says so.
---@param plan_ids string[]
---@param opts? { root?: string, date?: string, today?: string, checkpoint_dir?: string }
---@return Tasks.ClosedPlans
function M.close_plans(plan_ids, opts)
  opts = opts or {}
  ---@type Tasks.ClosedPlans
  local out = { closed = {}, projects = {}, refused = {}, summaries = {}, notes = {} }
  local files, seen = {}, {}
  for _, plan_id in ipairs(plan_ids) do
    if not seen[plan_id] then
      seen[plan_id] = true
      local file = plans.find(plan_id, { root = opts.root })
      if file then
        files[#files + 1] = file
      end
    end
  end
  if #files == 0 then
    return out
  end
  local all, errors = scan.all({ root = opts.root })
  if not all then
    out.notes[1] = ("the plans could not be checked: %s"):format(tostring(errors))
    return out
  end
  if type(errors) == "table" and #errors > 0 then
    for _, file in ipairs(files) do
      out.notes[#out.notes + 1] = ("the plan %s was not closed: the scan was incomplete (%s)"):format(
        file.id,
        tostring(errors[1])
      )
    end
    return out
  end
  -- A member that could not be read has no `plan:` here, so it cannot be attributed: every plan stays.
  for _, t in ipairs(all) do
    if t.error_codes and vim.tbl_contains(t.error_codes, "unreadable") then
      for _, file in ipairs(files) do
        out.notes[#out.notes + 1] = ("the plan %s was not closed: %s could not be read"):format(
          file.id,
          tostring(t.path)
        )
      end
      return out
    end
  end
  for _, file in ipairs(files) do
    local open, holding = 0, {}
    for _, t in ipairs(plans.members(file.id, all)) do
      if t.status ~= "done" then
        open = open + 1
        holding[#holding + 1] = t.id
      end
    end
    if open > 0 then
      table.sort(holding)
      out.refused[file.id] = holding
    end
    if open == 0 then
      local summary = plans.summary(file, { root = opts.root, date = opts.date or opts.today })
      local closed, cerr = plans.close(file.id, {
        root = opts.root,
        date = opts.date,
        today = opts.today,
        checkpoint_dir = opts.checkpoint_dir,
      })
      if not closed then
        out.notes[#out.notes + 1] = ("the plan %s could not be closed: %s"):format(
          file.id,
          tostring(cerr)
        )
      else
        out.closed[#out.closed + 1] = file.id
        out.projects[file.id] = file.project
        summary.title = file.title
        out.summaries[file.id] = summary
      end
    end
  end
  return out
end

---@class Tasks.ProjectSummary
---@field title? string
---@field plans integer            # Plans of the project, finished ones included.
---@field tasks integer            # Finished tasks of the project (in its plans and its own).
---@field parked_left string[]     # Open plans that were parked: they did not hold the project open and stay as they are.

---@class Tasks.ClosedProjects
---@field closed string[]                        # Ids of the project files that were finished.
---@field summaries table<string, Tasks.ProjectSummary>
---@field refused table<string, string[]>        # Project id -> the open tasks and plans that hold it open.
---@field notes string[]                         # Projects that could not be closed, or whose state could not be judged.

---The step after `close_plans`: finish every project of `project_ids` that has no open task of its own and no open plan
---left. A parked plan does not hold a project open (it is named in the summary); a plan or task of any other status
---does. A project that nothing finished is never asked about: an empty project does not close by itself. The scan
---guards are those of `close_plans`: an incomplete scan closes nothing.
---@param project_ids string[]
---@param opts? { root?: string, date?: string, today?: string, checkpoint_dir?: string }
---@return Tasks.ClosedProjects
function M.close_projects(project_ids, opts)
  opts = opts or {}
  ---@type Tasks.ClosedProjects
  local out = { closed = {}, summaries = {}, refused = {}, notes = {} }
  local files, seen = {}, {}
  for _, project_id in ipairs(project_ids) do
    if project_id and not seen[project_id] then
      seen[project_id] = true
      local file = projects.find(project_id, { root = opts.root })
      if file then
        files[#files + 1] = file
      end
    end
  end
  if #files == 0 then
    return out
  end
  local all, errors = scan.all({ root = opts.root })
  if not all then
    out.notes[1] = ("the projects could not be checked: %s"):format(tostring(errors))
    return out
  end
  if type(errors) == "table" and #errors > 0 then
    for _, file in ipairs(files) do
      out.notes[#out.notes + 1] = ("the project %s was not closed: the scan was incomplete (%s)"):format(
        file.id,
        tostring(errors[1])
      )
    end
    return out
  end
  for _, t in ipairs(all) do
    if t.error_codes and vim.tbl_contains(t.error_codes, "unreadable") then
      for _, file in ipairs(files) do
        out.notes[#out.notes + 1] = ("the project %s was not closed: %s could not be read"):format(
          file.id,
          tostring(t.path)
        )
      end
      return out
    end
  end
  local open_plans = plans.all({ root = opts.root }) or {}
  local open_tasks = {}
  for _, t in ipairs(all) do
    if model.is_open_status(t.status) then
      open_tasks[#open_tasks + 1] = t
    end
  end
  local finished
  for _, file in ipairs(files) do
    local holding, parked = {}, {}
    for _, t in ipairs(projects.members(file.id, all)) do
      if t.status ~= "done" then
        holding[#holding + 1] = t.id
      end
    end
    for _, f in ipairs(projects.plans_of(file.id, open_plans)) do
      if f.status == "parked" then
        parked[#parked + 1] = f.id
      elseif f.status ~= "done" then
        holding[#holding + 1] = f.id
      end
    end
    table.sort(holding)
    table.sort(parked)
    if #holding > 0 then
      out.refused[file.id] = holding
    else
      finished = finished or projects.finished_items({ root = opts.root })
      local rollup =
        projects.rollup(file, { plans = open_plans, open = open_tasks, finished = finished })
      local closed, cerr = projects.close(file.id, {
        root = opts.root,
        date = opts.date,
        today = opts.today,
        checkpoint_dir = opts.checkpoint_dir,
      })
      if not closed then
        out.notes[#out.notes + 1] = ("the project %s could not be closed: %s"):format(
          file.id,
          tostring(cerr)
        )
      else
        out.closed[#out.closed + 1] = file.id
        out.summaries[file.id] = {
          title = file.title,
          plans = rollup.plans_total,
          tasks = rollup.tasks_done,
          parked_left = parked,
        }
        if #parked > 0 then
          out.notes[#out.notes + 1] = ("the project %s is finished; its parked plan(s) stay: %s"):format(
            file.id,
            table.concat(parked, ", ")
          )
        end
      end
    end
  end
  return out
end

---Reset the ticked boxes (`- [x]`) of a task text to open ones, in the body only (below the frontmatter).
---@param text string
---@return string
local function reopen_boxes(text)
  local lines = vim.split(text, "\n", { plain = true })
  local fences = 0
  for i, line in ipairs(lines) do
    if fences >= 2 then
      lines[i] = line:gsub("^(%s*[-*+]%s+)%[[xX]%]", "%1[ ]")
    elseif line:match("^%-%-%-%s*$") then
      fences = fences + 1
    end
  end
  return table.concat(lines, "\n")
end

---The routine a task is, read before it is finished: the open task and the text of its file. `nil` when it is none.
---@param id string
---@param opts table
---@return { task: Tasks.Task, text: string }|nil
local function read_routine(id, opts)
  local root = vault.root(opts)
  if not root then
    return nil
  end
  local task = mutate.find_open(id, root)
  if not task or not model.is_repeat(task.repeat_every) then
    return nil
  end
  local text = fsio.read(task.path)
  if not text then
    return nil
  end
  return { task = task, text = text }
end

---Start the next round of a routine whose finish just succeeded.
---@param routine { task: Tasks.Task, text: string }
---@param opts table
---@return { id: string, due: string, path: string }|nil round
---@return string|nil err
local function start_next_round(routine, opts)
  local task = routine.task
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local today = opts.today or model.today()
  local done_date = opts.date or today
  local due = model.next_round_due(task, done_date, today)
  if not due then
    return nil, "the next due date cannot be worked out from repeat " .. tostring(task.repeat_every)
  end
  -- what belongs to the finished round goes; what describes the routine stays (title, tags, fields, body)
  local text, uerr = fm.update_text(routine.text, {
    { "status", "open" },
    { "waits_for", mutate.REMOVE },
    { "commits", mutate.REMOVE },
    { "done_in", mutate.REMOVE },
    { "blocked_by", mutate.REMOVE },
    -- the round is not ready before its due day: `next` and `list --ready` honour `start`
    { "start", due },
    { "remind", due },
    { "due", due },
    { "created", today },
    { "updated", today },
  })
  if not text then
    return nil, tostring(uerr)
  end
  text = reopen_boxes(text)
  -- the base of the slug: without the date a round before this one carries; room is left for the date
  local base = task.slug:gsub("%-%d%d%d%d%-%d%d%-%d%d$", "")
  base = base:sub(1, mutate.MAX_SLUG - #due - 1):gsub("%-+$", "")
  local slug = base .. "-" .. due
  local path = vault.tasks_dir(root, task.area) .. "/" .. slug .. ".md"
  local ok, werr = fsio.create_exclusive(path, text)
  if not ok then
    return nil, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  if opts.index ~= false then
    local res, ierr = index.write_area(task.area, { root = root })
    if not res then
      return nil,
        "the next round is written, the index could not be regenerated: " .. tostring(ierr)
    end
  end
  return { id = task.area .. "/" .. slug, due = due, path = path }, nil
end

---@class Tasks.DoneFlowPreview : Tasks.DonePreview
---@field closes_plan? string   # The plan file this finish closes: the task is its last open member.
---@field closes_project? string # The project file this finish closes after that: no other plan (a parked one does not count) and no task of its own is open.
---@field freed string[]        # Open tasks that wait on nothing but this one.
---@field next_round? { due: string }  # The due date of the next round, when the task is a routine.

---What finishing `id` would do, chain included, with nothing written: `mutate.done_preview` plus the plan it would
---close and the tasks it would free. The `confirm` token in the answer is what `run` is confirmed with.
---@param id string
---@param opts? Tasks.DoneFlowOpts
---@return Tasks.DoneFlowPreview|nil preview
---@return string|nil err
---@return table|nil info
function M.preview(id, opts)
  opts = opts or {}
  local pv, err, info = mutate.done_preview(id, opts)
  if not pv then
    return nil, err, info
  end
  ---@cast pv Tasks.DoneFlowPreview
  pv.freed = {}
  if pv.already then
    return pv, nil
  end
  if not opts.last then
    local routine = read_routine(id, opts)
    if routine then
      local today = opts.today or model.today()
      local due = model.next_round_due(routine.task, opts.date or today, today)
      pv.next_round = due and { due = due } or nil
    end
  end
  -- the chain: judged on one pass over the vault, as `plan` and `next` judge it
  local all, scan_errors = scan.all({ root = opts.root })
  local shared = all
    and plan_scope.shared(
      opts.root,
      { all = all, errors = type(scan_errors) == "table" and scan_errors or {} }
    )
  if all and shared then
    local built = require("tasks_nvim.plan").build(shared.open, shared.index)
    for _, t in ipairs(shared.open) do
      local node = built.nodes[t.id]
      if node and #node.open_blockers == 1 and node.open_blockers[1] == id then
        pv.freed[#pv.freed + 1] = t.id
      end
    end
    table.sort(pv.freed)
    if pv.plan_id then
      local file = plans.find(pv.plan_id, { root = opts.root })
      if file then
        local others = 0
        for _, m in ipairs(plans.members(file.id, all)) do
          if m.id ~= id and m.status ~= "done" then
            others = others + 1
          end
        end
        if others == 0 then
          pv.closes_plan = file.id
        end
      end
    end
    -- the project after it: the one of the plan this finish closes, or the one the task belongs to itself
    local project_id = pv.project_id
    if pv.closes_plan then
      local closing = plans.find(pv.closes_plan, { root = opts.root })
      project_id = closing and closing.project or project_id
    end
    if project_id then
      for _, project in ipairs(shared.projects) do
        if project.id == project_id then
          local holding = false
          for _, t in ipairs(shared.open) do
            if t.id ~= id and t.project == project_id then
              holding = true
            end
          end
          for _, f in ipairs(shared.files) do
            if
              f.project == project_id
              and f.id ~= pv.closes_plan
              and f.status ~= "parked"
              and f.status ~= "done"
            then
              holding = true
            end
          end
          if not holding then
            pv.closes_project = project_id
          end
        end
      end
    end
  end
  return pv, nil
end

---Finish `id`.
---@param id string
---@param opts? Tasks.DoneFlowOpts
---@return Tasks.DoneFlow|nil flow
---@return string|nil err   # The finish failed (nothing changed, or the rollback says what it could not undo).
---@return table|nil info   # `{ code = "conflict", ... }` when `opts.if_match` is not the version of the file.
function M.run(id, opts)
  opts = opts or {}
  local routine = not opts.last and not opts.drafts and read_routine(id, opts) or nil
  -- a claim of somebody else that this finish goes past (force and a note): written into the finished task afterwards
  local passed
  do
    local claims = require("tasks_nvim.claims")
    local root = vault.root(opts)
    passed = root and claims.overridden(root, id, opts) or nil
  end
  -- Step a is part of the finish itself: the ticked text is what `mutate.done` writes as the finished copy.
  local done, err, info =
    mutate.done(id, vim.tbl_extend("force", opts, { tick_steps = opts.chain ~= false }))
  if not done then
    return nil, err, info
  end
  ---@type Tasks.DoneFlow
  local flow = {
    done = done,
    steps_ticked = 0,
    freed = {},
    plans_closed = {},
    plan_summaries = {},
    projects_closed = {},
    project_summaries = {},
    docs_refreshed = {},
    notes = {},
  }
  flow.steps_ticked = done.steps_ticked or 0
  if done.already then
    return flow, nil
  end
  if passed and done.to then
    require("tasks_nvim.claims").record_override_in_file(done.to, passed, opts)
  end
  -- the routine first: the plan below must see the open next round, or it would close a plan that goes on
  if routine then
    local ran, round, rerr = pcall(start_next_round, routine, opts)
    if ran and round then
      flow.next_round = round
    else
      flow.notes[#flow.notes + 1] = ("the next round of %s was not started: %s"):format(
        id,
        tostring(ran and rerr or round)
      )
    end
  end
  if opts.chain == false then
    return flow, nil
  end
  -- Each follow-up step runs in its own pcall so that one cannot cost the others; a failure is a note.
  ---@param what string
  ---@param fn fun()
  local function step(what, fn)
    local ran, perr = pcall(fn)
    if not ran then
      flow.notes[#flow.notes + 1] = ("%s: %s"):format(what, tostring(perr))
    end
  end

  -- b. the plan this task belonged to: finished when no member is left open
  local project_ids = { done.project_id }
  if done.plan_id and not opts.defer_plan_close then
    step("closing the plan " .. done.plan_id, function()
      local res = M.close_plans({ done.plan_id }, opts)
      vim.list_extend(flow.plans_closed, res.closed)
      vim.list_extend(flow.notes, res.notes)
      for plan_id, summary in pairs(res.summaries) do
        flow.plan_summaries[plan_id] = summary
      end
      for _, plan_id in ipairs(res.closed) do
        project_ids[#project_ids + 1] = res.projects[plan_id]
      end
    end)
  end

  -- b2. the project: of the plan that was just finished, or the one the task belongs to itself. Finished when no
  -- plan (other than a parked one) and no task of its own is left open. A batch does this once at its end.
  if #project_ids > 0 and not opts.defer_plan_close then
    step("closing the project", function()
      local res = M.close_projects(project_ids, opts)
      vim.list_extend(flow.projects_closed, res.closed)
      vim.list_extend(flow.notes, res.notes)
      for project_id, summary in pairs(res.summaries) do
        flow.project_summaries[project_id] = summary
      end
    end)
  end

  -- c. the generated blocks of the documents the user named, and only those (a batch does this once at its end)
  if opts.refresh_docs ~= false then
    step("refreshing generated plan blocks", function()
      local refreshed, notes =
        M.refresh_marker_docs({ root = opts.root, closed = flow.plan_summaries })
      vim.list_extend(flow.docs_refreshed, refreshed)
      vim.list_extend(flow.notes, notes)
    end)
  end

  -- d. the freed tasks and e. the next task
  if opts.pick_next ~= false then
    local ran, pick, perr = pcall(next_pick.pick_from_vault, {
      root = opts.root,
      done = { id = done.id, area = done.area },
    })
    if ran and pick then
      flow.next = pick
      flow.freed = pick.freed
    else
      flow.notes[#flow.notes + 1] = "the next task could not be worked out: "
        .. tostring(ran and perr or pick)
    end
  end
  return flow, nil
end

return M
