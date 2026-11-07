-- TESTS/tasks_projects_spec.lua -- project files (`ROADMAP/projects/`), `project:` / `phase:` of a plan file, `project:` of a
-- task, the rollup of a project, the soft stage order across its plans and the `check` codes that belong to them.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local plans = require("tasks_nvim.plans")
  local plan = require("tasks_nvim.plan")
  local projects = require("tasks_nvim.projects")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local mutate = require("tasks_nvim.mutate")

  ---@param extra table[]
  ---@param kind? "plan"|"project"
  ---@return Tasks.PlanFile
  local function parse(extra, kind)
    local lines = { "---" }
    for _, kv in ipairs(extra) do
      lines[#lines + 1] = kv[1] .. ": " .. kv[2]
    end
    lines[#lines + 1] = "---"
    local dir = kind == "project" and "projects" or "plans"
    return plans.parse(table.concat(lines, "\n") .. "\nOne line of goal.\n", {
      path = "/v/a/ROADMAP/" .. dir .. "/big.md",
      area = "a",
      kind = kind,
    })
  end

  -- ── reading a project file and the fields of a plan file ──
  local project = parse({
    { "title", "Mobile" },
    { "status", "planning" },
    { "areas", "[a, b]" },
    { "phase_order", "[basis, apps]" },
  }, "project")
  ok(project.valid, table.concat(project.errors, "; "))
  eq(project.id, "a/big")
  eq(project.kind, "project")
  eq(project.phase_order, { "basis", "apps" })

  local member = parse({
    { "title", "App" },
    { "status", "planning" },
    { "project", "a/big" },
    { "phase", "apps" },
  })
  ok(member.valid, table.concat(member.errors, "; "))
  eq(member.kind, "plan")
  eq(member.project, "a/big")
  eq(member.phase, "apps")

  for _, case in ipairs({
    { { { "title", "T" }, { "status", "wip" } }, "project-bad-status" },
    { { { "title", "T" }, { "status", "doing" }, { "gate", "soft" } }, "project-bad-gate" },
    { { { "title", "T" }, { "status", "doing" }, { "project", "a/other" } }, "project-nested" },
    { { { "title", "T" }, { "status", "doing" }, { "phase", "x" } }, "project-nested" },
  }) do
    local broken = parse(case[1], "project")
    ok(not broken.valid)
    eq(broken.error_codes[1], case[2])
  end
  for _, case in ipairs({
    { { { "title", "T" }, { "status", "doing" }, { "project", "nope" } }, "plan-bad-project" },
    {
      { { "title", "T" }, { "status", "doing" }, { "project", "a/x" }, { "phase", "Not A Word" } },
      "bad-phase",
    },
  }) do
    local broken = parse(case[1])
    ok(not broken.valid)
    eq(broken.error_codes[1], case[2])
  end

  -- ── a task names a project ──
  local own = model.parse_text(
    F.text(F.meta("Own", "open", { { "project", "a/big" }, { "phase", "basis" } })),
    { path = "/v/a/ROADMAP/tasks/own.md", area = "a", location = "roadmap" }
  )
  ok(own.valid, table.concat(own.errors, "; "))
  eq(own.project, "a/big")
  eq(own.phase, "basis")
  local bad_project = model.parse_text(
    F.text(F.meta("Bad", "open", { { "project", "not-an-id" } })),
    { path = "/v/a/ROADMAP/tasks/bad.md", area = "a", location = "roadmap" }
  )
  ok(not bad_project.valid)
  eq(bad_project.error_codes[1], "bad-project")

  -- ── the soft stage order across the plans of a project ──
  local function task(id, fields)
    return vim.tbl_extend("force", { id = id, status = "open", blocked_by = {} }, fields)
  end
  local stage_project = parse({
    { "title", "P" },
    { "status", "doing" },
    { "phase_order", "[one, two, three]" },
  }, "project")
  stage_project.id = "a/prj"
  local plan_one =
    parse({ { "title", "One" }, { "status", "doing" }, { "project", "a/prj" }, { "phase", "one" } })
  plan_one.id = "a/plan-one"
  local plan_two =
    parse({ { "title", "Two" }, { "status", "doing" }, { "project", "a/prj" }, { "phase", "two" } })
  plan_two.id = "a/plan-two"
  local stages = plan.index({
    task("a/t1", { plan = "a/plan-one" }),
    task("a/t2", { plan = "a/plan-two" }),
    task("a/t3", { project = "a/prj", phase = "three" }),
    task("a/t4", { plan = "a/elsewhere" }),
  }, nil, { plan_one, plan_two }, { stage_project })
  eq(stages.phase_edges["a/t2"], { "a/t1" }, "a later stage follows the earlier one")
  eq(stages.phase_edges["a/t3"], { "a/t2" }, "a task of the project itself takes part")
  eq(stages.phase_edges["a/t1"], nil)
  eq(stages.phase_edges["a/t4"], nil, "a plan outside the project is left alone")
  eq(next(stages.gate_blockers), nil, "across plans the order stays soft")

  -- ── a vault with a project ──
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY }
  local function write(path, text)
    H.write(root .. "/" .. path, text)
  end
  write(
    "ALL/ROADMAP/projects/mobile.md",
    F.text({
      { "title", "Mobile" },
      { "status", "doing" },
      { "areas", "[ALL]" },
      { "phase_order", "[basis, apps]" },
    })
  )
  write(
    "lib.nvim/ROADMAP/plans/lib-mobile.md",
    F.text({
      { "title", "lib mobile" },
      { "status", "doing" },
      { "project", "ALL/mobile" },
      { "phase", "apps" },
    })
  )
  write(
    "cascade.nvim/ROADMAP/plans/basis.md",
    F.text({
      { "title", "basis" },
      { "status", "parked" },
      { "project", '"[[mobile]]"' },
      { "phase", "basis" },
    })
  )
  -- a closed plan of the project (it lands in the Backlog as it is) with a finished task of its own
  write(
    "cascade.nvim/Backlog/FEATURES/2026-10-01_old-plan.md",
    F.text({
      { "title", "old plan" },
      { "status", "done" },
      { "areas", "[cascade.nvim]" },
      { "project", "ALL/mobile" },
      { "updated", "2026-10-01" },
    })
  )
  write(
    "cascade.nvim/Backlog/TASKS/2026-10-01_old-task.md",
    F.text(F.meta("Old task", "done", { { "plan", "cascade.nvim/old-plan" } }))
  )
  write(
    "lib.nvim/Backlog/TASKS/2026-10-02_own-done.md",
    F.text(F.meta("Own done", "done", { { "project", "ALL/mobile" } }))
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "in-plan",
    F.meta("In plan", "open", {
      { "plan", "lib.nvim/lib-mobile" },
      { "effort", "M" },
    })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "in-plan-2",
    F.meta("In plan 2", "doing", { { "plan", "lib.nvim/lib-mobile" } })
  )
  F.task(
    H,
    root,
    "ALL",
    "decide",
    F.meta("Decide", "open", { { "project", "ALL/mobile" }, { "effort", "S" } })
  )
  F.task(H, root, "cascade.nvim", "elsewhere", F.meta("Elsewhere", "open"))
  for _, a in ipairs({ "lib.nvim", "cascade.nvim", "ALL" }) do
    assert(index.write_area(a, o))
  end

  local found = assert(projects.find("ALL/mobile", o))
  ok(found.valid, table.concat(found.errors, "; "))
  eq(
    vim.tbl_map(function(f)
      return f.id
    end, projects.all(o)),
    { "ALL/mobile" }
  )
  eq(select(2, projects.find("ALL/ghost", o)), "no such open project: ALL/ghost")

  local files = assert(plans.all(o))
  eq(
    vim.tbl_map(function(f)
      return f.project
    end, projects.plans_of("ALL/mobile", files)),
    { "ALL/mobile", "ALL/mobile" },
    "a wikilink to the project reads as its id"
  )

  local open = assert(scan.open_tasks(o))
  local rollup = projects.rollup(found, { plans = files, open = open, root = root })
  eq(rollup.plans_total, 3, "two open plans and one closed")
  eq(rollup.plans_done, 1)
  eq(rollup.plans_parked, 1)
  eq(rollup.tasks_open, 3, "two in the plan, one of the project's own")
  eq(rollup.own_open, 1)
  eq(rollup.tasks_done, 2, "one of the closed plan, one of the project's own")
  eq(rollup.days_open, model.effort_days("M") + model.effort_days("S"))
  eq(rollup.plan_ids, { "cascade.nvim/basis", "lib.nvim/lib-mobile" })

  -- ── check ──
  local function codes(res)
    local out = {}
    for _, f in ipairs(res.findings) do
      out[#out + 1] = (f.severity == "warn" and "warn:" or "") .. f.code
    end
    table.sort(out)
    return out
  end
  local function run()
    return assert(check.run({ root = root }))
  end
  eq(codes(run()), {}, "a vault with a project, its plans and tasks checks clean")

  local own_path = root .. "/ALL/ROADMAP/tasks/decide.md"
  assert(mutate.set("ALL/decide", { plan = "lib.nvim/lib-mobile" }, o))
  eq(codes(run()), { "task-plan-and-project" }, "plan: and project: together")
  assert(mutate.set("ALL/decide", { plan = mutate.REMOVE, project = "ALL/ghost" }, o))
  eq(codes(run()), { "project-unknown" })
  assert(mutate.set("ALL/decide", { project = "ALL/mobile", phase = "invented" }, o))
  eq(codes(run()), { "warn:project-phase" })
  assert(mutate.set("ALL/decide", { phase = mutate.REMOVE }, o))
  ok(own_path ~= "")

  -- a plan outside the project's stages, one without a project, one under a project nobody wrote
  local plan_path = root .. "/lib.nvim/ROADMAP/plans/lib-mobile.md"
  local original = H.read(plan_path)
  H.write(plan_path, (original:gsub("phase: apps", "phase: invented")))
  eq(codes(run()), { "warn:plan-project-phase" })
  H.write(plan_path, (original:gsub("project: ALL/mobile\n", "")))
  eq(codes(run()), { "plan-phase-without-project" })
  H.write(plan_path, (original:gsub("project: ALL/mobile", "project: ALL/ghost")))
  eq(codes(run()), { "plan-project-unknown" })
  H.write(plan_path, original)
  eq(codes(run()), {})

  -- a project file with a gate, one that is nested, one that is broken
  local project_path = root .. "/ALL/ROADMAP/projects/mobile.md"
  local project_text = H.read(project_path)
  H.write(project_path, (project_text:gsub("status: doing", "status: doing\ngate: hard")))
  eq(codes(run()), { "warn:project-gate-soft" })
  H.write(project_path, (project_text:gsub("status: doing", "status: doing\nproject: ALL/other")))
  eq(codes(run()), { "project-nested" })
  H.write(project_path, (project_text:gsub("status: doing", "status: wip")))
  eq(codes(run()), { "project-bad-status" })
  H.write(project_path, project_text)
  eq(codes(run()), {})

  -- a task of the project in an area the project does not list
  F.task(H, root, "cascade.nvim", "stray", F.meta("Stray", "open", { { "project", "ALL/mobile" } }))
  assert(index.write_area("cascade.nvim", o))
  eq(codes(run()), { "warn:project-area" })

  -- a project and a plan or task of the same name are one id twice: a new task or plan takes another slug
  local made = assert(mutate.new("ALL", { title = "Mobile", today = F.TODAY, root = root }))
  eq(made.id, "ALL/mobile-2", "a task does not take the slug of a project")
  local made_plan = assert(plans.new("ALL", { root = root, today = F.TODAY, title = "Mobile" }))
  eq(made_plan.slug, "mobile-3", "nor does a plan")
end
