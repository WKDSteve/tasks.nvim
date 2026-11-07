-- TESTS/tasks_project_ops_spec.lua -- the write door and projects: `project_new`, `plan_new` with a project, `plan_set`,
-- `project_set`, `plan_close`, `project_close`, and the relations a task may name (`project:`).

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local plans = require("tasks_nvim.plans")
  local projects = require("tasks_nvim.projects")
  local scan = require("tasks_nvim.scan")
  local index = require("tasks_nvim.index")
  local check = require("tasks_nvim.check")

  local root = F.vault(H)
  local function ops(list, extra)
    local text, code = api.call(
      "ops",
      vim.json.encode(vim.tbl_extend("force", { ops = list }, extra or {})),
      { root = root, today = F.TODAY }
    )
    return vim.json.decode(text), code
  end
  local function one(list, extra)
    local doc = ops(list, extra)
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    assert(doc.results, tostring(doc.message))
    eq(#doc.results, 1)
    return doc.results[1]
  end
  local function confirm_of(id)
    return assert(require("tasks_nvim.contract").done_preview(id, { root = root })).confirm
  end
  local function exists(path)
    return vim.uv.fs_stat(root .. "/" .. path) ~= nil
  end
  local function everything()
    local out = {}
    for _, path in ipairs(vim.fn.globpath(root, "**/*", true, true)) do
      if vim.fn.isdirectory(path) == 0 then
        out[path] = H.read(path)
      end
    end
    return out
  end

  -- ── project_new: a dry run names it, the real run makes it ──
  local before = everything()
  local dry = one({
    {
      op = "project_new",
      area = "ALL",
      title = "Mobile",
      areas = { "ALL", "lib.nvim" },
      phases = { "basis", "apps" },
      summary = "Apps for the families.",
    },
  }, { dry_run = true })
  eq(dry.ok, true, vim.inspect(dry))
  eq(dry.outcome, "would_create")
  eq(dry.id, "ALL/mobile")
  eq(dry.file, "ALL/ROADMAP/projects/mobile.md")
  eq(everything(), before, "a dry run writes nothing")
  local made = one({
    {
      op = "project_new",
      area = "ALL",
      title = "Mobile",
      areas = { "ALL", "lib.nvim" },
      phases = { "basis", "apps" },
    },
  })
  eq(made.ok, true, vim.inspect(made))
  eq(made.id, "ALL/mobile")
  eq(made.changed_ids, { "ALL/mobile" })
  local project = assert(projects.find("ALL/mobile", { root = root }))
  ok(project.valid, table.concat(project.errors, "; "))
  eq(project.phase_order, { "basis", "apps" })
  eq(project.kind, "project")
  -- the id namespace: a plan or a project of that name is not made twice
  eq(one({ { op = "plan_new", area = "ALL", title = "Mobile" } }).id, "ALL/mobile-2")
  eq(one({ { op = "project_new", area = "ALL", title = "Mobile" } }).id, "ALL/mobile-3")
  -- a project is not part of a project
  local nested = ops({
    { op = "project_new", area = "ALL", title = "Nested", project = "ALL/mobile" },
  })
  eq(nested.code, "invalid_argument", "the shape check: a project has no project field")
  has(nested.message, "unknown field 'project'")
  os.remove(root .. "/ALL/ROADMAP/plans/mobile-2.md")
  os.remove(root .. "/ALL/ROADMAP/projects/mobile-3.md")

  -- ── plan_new into a project ──
  local plan = one({
    {
      op = "plan_new",
      area = "lib.nvim",
      title = "lib mobile",
      project = "ALL/mobile",
      phase = "apps",
    },
  })
  eq(plan.ok, true, vim.inspect(plan))
  local plan_file = assert(plans.find("lib.nvim/lib-mobile", { root = root }))
  eq({ plan_file.project, plan_file.phase }, { "ALL/mobile", "apps" })
  local ghost = one({ { op = "plan_new", area = "lib.nvim", title = "x", project = "ALL/ghost" } })
  eq(ghost.ok, false)
  eq(ghost.error.code, "invalid_argument")
  has(ghost.error.message, "no such open project")
  local stage = one({
    { op = "plan_new", area = "lib.nvim", title = "y", project = "ALL/mobile", phase = "nope" },
  })
  eq(stage.ok, false)
  has(stage.error.message, "not in the phase_order")
  eq(
    one({ { op = "plan_new", area = "lib.nvim", title = "z", phase = "apps" } }).ok,
    false,
    "a stage without a project"
  )

  -- ── plan_set: judged as the file would read, a version check, an inverse ──
  local plan_path = root .. "/lib.nvim/ROADMAP/plans/lib-mobile.md"
  local etag = require("tasks_nvim.fsio").etag(H.read(plan_path))
  -- the snapshot names the version of every plan and project file: a reader sends it as `if_match` at once
  local function snapshot_entry(list, id)
    local doc = vim.json.decode((api.call("snapshot", nil, { root = root, today = F.TODAY })))
    for _, e in ipairs(doc[list]) do
      if e.id == id then
        return e
      end
    end
    error(id .. " is not in snapshot." .. list)
  end
  eq(snapshot_entry("plans", "lib.nvim/lib-mobile").etag, etag)
  local changed = one({
    {
      op = "plan_set",
      id = "lib.nvim/lib-mobile",
      patch = { status = "doing", phase = "basis" },
      if_match = etag,
    },
  })
  eq(changed.ok, true, vim.inspect(changed))
  eq(changed.outcome, "changed")
  eq(changed.changed_ids, { "lib.nvim/lib-mobile" })
  plan_file = assert(plans.find("lib.nvim/lib-mobile", { root = root }))
  eq({ plan_file.status, plan_file.phase }, { "doing", "basis" })
  eq(changed.inverse.op, "plan_set")
  eq(changed.inverse.patch, { status = "planning", phase = "apps" })
  eq(changed.inverse.if_match, changed.etag_after)
  -- the inverse puts it back
  local undone = one({ changed.inverse })
  eq(undone.ok, true, vim.inspect(undone))
  plan_file = assert(plans.find("lib.nvim/lib-mobile", { root = root }))
  eq({ plan_file.status, plan_file.phase }, { "planning", "apps" })
  -- the version: a tag that is not the file's is a conflict (the undo above made the very same bytes again)
  local stale = one({
    {
      op = "plan_set",
      id = "lib.nvim/lib-mobile",
      patch = { status = "parked" },
      if_match = "sha256:0000000000000000",
    },
  })
  eq(stale.ok, false)
  eq(stale.error.code, "conflict")
  -- what is refused, with the file untouched
  local snapshot = everything()
  for _, case in ipairs({
    { { status = "done" }, "invalid_argument", "close" },
    { { status = "wip" }, "invalid_argument", "unknown plan status" },
    { { phase = "nope" }, "invalid_argument", "not in the phase_order" },
    { { project = "ALL/ghost" }, "invalid_argument", "no such open project" },
    { { gate = "soft" }, "invalid_argument", "gate must be" },
    { { colour = "red" }, "invalid_argument", "unknown field" },
    { {}, "invalid_argument", "empty" },
    { { title = vim.NIL }, "invalid_argument", "cannot be removed" },
  }) do
    local refused = one({ { op = "plan_set", id = "lib.nvim/lib-mobile", patch = case[1] } })
    eq(refused.ok, false, vim.inspect(case[1]))
    eq(refused.error.code, case[2])
    has(refused.error.message, case[3])
  end
  eq(everything(), snapshot, "a refused change writes nothing")
  -- a dry run
  local dry_set = one(
    { { op = "plan_set", id = "lib.nvim/lib-mobile", patch = { status = "parked" } } },
    { dry_run = true }
  )
  eq(dry_set.outcome, "would_change")
  eq(everything(), snapshot)
  -- taking the project away takes the stage away first
  eq(
    one({ { op = "plan_set", id = "lib.nvim/lib-mobile", patch = { project = vim.NIL } } }).ok,
    false
  )
  local loose = one({
    { op = "plan_set", id = "lib.nvim/lib-mobile", patch = { project = vim.NIL, phase = vim.NIL } },
  })
  eq(loose.ok, true, vim.inspect(loose))
  eq(assert(plans.find("lib.nvim/lib-mobile", { root = root })).project, nil)
  eq(
    one({ { op = "plan_set", id = "lib.nvim/lib-mobile", patch = { project = "ALL/mobile" } } }).ok,
    true
  )
  eq(
    one({ { op = "plan_set", id = "lib.nvim/ghost", patch = { status = "doing" } } }).error.code,
    "not_found"
  )

  -- ── project_set ──
  local project_etag = snapshot_entry("projects", "ALL/mobile").etag
  eq(
    project_etag,
    require("tasks_nvim.fsio").etag(H.read(root .. "/ALL/ROADMAP/projects/mobile.md"))
  )
  local pset = one({
    {
      op = "project_set",
      id = "ALL/mobile",
      patch = { gate = "hard", areas = { "ALL" }, status = "doing" },
      if_match = project_etag,
    },
  })
  eq(pset.ok, true, vim.inspect(pset))
  project = assert(projects.find("ALL/mobile", { root = root }))
  eq({ project.gate, project.areas, project.status }, { "hard", { "ALL" }, "doing" })
  eq(pset.inverse.patch.gate, vim.NIL, "a key the file did not have is removed by the inverse")
  -- the version the snapshot named before the change is stale now
  eq(
    one({
      {
        op = "project_set",
        id = "ALL/mobile",
        patch = { status = "parked" },
        if_match = project_etag,
      },
    }).error.code,
    "conflict"
  )
  eq(snapshot_entry("projects", "ALL/mobile").etag, pset.etag_after)
  eq(one({ { op = "project_set", id = "ALL/mobile", patch = { project = "ALL/x" } } }).ok, false)
  eq(one({ { op = "project_set", id = "ALL/mobile", patch = { gate = vim.NIL } } }).ok, true)

  -- ── a task names a project ──
  local new_task = one({
    {
      op = "new",
      area = "ALL",
      title = "Decide",
      fields = { project = "ALL/mobile", phase = "basis" },
    },
  })
  eq(new_task.ok, true, vim.inspect(new_task))
  local task = assert(scan.find("ALL/decide", { root = root }))
  eq({ task.project, task.phase, task.plan }, { "ALL/mobile", "basis", nil })
  local both = one({
    {
      op = "new",
      area = "ALL",
      title = "Both",
      fields = { project = "ALL/mobile", plan = "lib.nvim/lib-mobile" },
    },
  })
  eq(both.ok, false)
  eq(both.error.details.problems[1].code, "task-plan-and-project")
  local unknown = one({
    { op = "new", area = "ALL", title = "Lost", fields = { project = "ALL/ghost" } },
  })
  eq(unknown.error.details.problems[1].code, "project-unknown")
  local bad_stage = one({
    {
      op = "new",
      area = "ALL",
      title = "Stage",
      fields = { project = "ALL/mobile", phase = "nope" },
    },
  })
  eq(bad_stage.error.details.problems[1].code, "project-phase")
  local set_both =
    one({ { op = "set", id = "ALL/decide", patch = { plan = "lib.nvim/lib-mobile" } } })
  eq(set_both.error.details.problems[1].code, "task-plan-and-project")
  eq(
    one({ { op = "set", id = "ALL/decide", patch = { project = "ALL/ghost" } } }).error.details.problems[1].code,
    "project-unknown"
  )
  eq(one({ { op = "set", id = "ALL/decide", patch = { phase = "apps" } } }).ok, true)
  eq(
    one({ { op = "set", id = "ALL/decide", patch = { project = vim.NIL, phase = vim.NIL } } }).ok,
    true
  )
  eq(one({ { op = "set", id = "ALL/decide", patch = { project = "ALL/mobile" } } }).ok, true)
  assert(index.write_area("ALL", { root = root, today = F.TODAY }))
  local codes = {}
  for _, f in ipairs(assert(check.run({ root = root })).findings) do
    codes[#codes + 1] = f.code
  end
  eq(codes, {}, "everything the door made checks clean")

  -- ── plan_close and project_close ──
  F.task(H, root, "lib.nvim", "t1", F.meta("T1", "open", { { "plan", "lib.nvim/lib-mobile" } }))
  assert(index.write_area("lib.nvim", { root = root, today = F.TODAY }))
  -- the filter `project` of list and order: the tasks of its plans and its own
  local function listed(method, params)
    local text =
      api.call(method, vim.json.encode({ params = params }), { root = root, today = F.TODAY })
    return vim.json.decode(text)
  end
  local by_project = listed("list", { project = { "ALL/mobile" } })
  assert(by_project.items, tostring(by_project.message))
  local found = {}
  for _, item in ipairs(by_project.items) do
    found[#found + 1] = item.id
  end
  table.sort(found)
  eq(found, { "ALL/decide", "lib.nvim/t1" }, "a task of the plan and one of the project itself")
  eq(listed("list", { project = { "ALL/ghost" } }).total, 0)
  eq(listed("list", { project = {} }).total >= 2, true, "an empty list narrows nothing")
  eq(listed("list", { project = { "mobile" } }).code, "invalid_argument")
  local ordered = listed("order", { project = { "ALL/mobile" } })
  table.sort(ordered.ids)
  eq(ordered.ids, { "ALL/decide", "lib.nvim/t1" })

  local held = one({ { op = "plan_close", id = "lib.nvim/lib-mobile" } })
  eq(held.ok, false)
  eq(held.error.code, "invalid_argument")
  eq(held.error.details.holding, { "lib.nvim/t1" })
  eq(one({ { op = "plan_close", id = "lib.nvim/lib-mobile" } }, { dry_run = true }).ok, false)
  eq(one({ { op = "project_close", id = "ALL/mobile" } }).error.details.holding[1], "ALL/decide")
  local fine = one({ { op = "done", id = "lib.nvim/t1", confirm = confirm_of("lib.nvim/t1") } })
  eq(fine.ok, true)
  -- the finish closed the plan already; the project still has a task of its own
  ok(not exists("lib.nvim/ROADMAP/plans/lib-mobile.md"))
  ok(exists("ALL/ROADMAP/projects/mobile.md"))
  eq(
    one({ { op = "plan_close", id = "lib.nvim/lib-mobile" } }).outcome,
    "unchanged",
    "closing again"
  )
  local last = one({ { op = "done", id = "ALL/decide", confirm = confirm_of("ALL/decide") } })
  eq(last.ok, true, vim.inspect(last))
  eq(last.projects_closed, { "ALL/mobile" })
  ok(not exists("ALL/ROADMAP/projects/mobile.md"))
  eq(one({ { op = "project_close", id = "ALL/mobile" } }).outcome, "unchanged")
  eq(one({ { op = "project_close", id = "ALL/ghost" } }).error.code, "not_found")

  -- by hand: an empty plan and its project
  one({ { op = "project_new", area = "ALL", title = "Hand" } })
  one({ { op = "plan_new", area = "lib.nvim", title = "Hand plan", project = "ALL/hand" } })
  local dry_close = one({ { op = "plan_close", id = "lib.nvim/hand-plan" } }, { dry_run = true })
  eq(dry_close.outcome, "would_close")
  ok(exists("lib.nvim/ROADMAP/plans/hand-plan.md"), "a dry run closes nothing")
  local closed = one({ { op = "plan_close", id = "lib.nvim/hand-plan" } })
  eq(closed.ok, true, vim.inspect(closed))
  eq(closed.outcome, "closed")
  eq(closed.plans_closed, { "lib.nvim/hand-plan" })
  eq(closed.projects_closed, { "ALL/hand" })
  eq(closed.changed_ids, { "lib.nvim/hand-plan", "ALL/hand" })
end
