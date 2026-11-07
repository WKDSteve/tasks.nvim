-- TESTS/tasks_project_close_spec.lua -- finishing the last plan or own task of a project finishes the project: the done
-- chain (`done_flow`), the preview, a batch, and the hand-made `plan-close` / `project-close`.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local done_flow = require("tasks_nvim.done_flow")
  local batch = require("tasks_nvim.batch")
  local projects = require("tasks_nvim.projects")
  local scan = require("tasks_nvim.scan")
  local check = require("tasks_nvim.check")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")
  local plan_view = require("tasks_nvim.plan_view")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, date = F.TODAY }

  ---@param path string
  ---@param meta table[]
  local function write(path, meta)
    H.write(root .. "/" .. path, F.text(meta))
  end
  local function exists(path)
    return vim.uv.fs_stat(root .. "/" .. path) ~= nil
  end

  --- A project `ALL/mobile` with two plans (one parked) and one task of its own.
  local function setup_vault()
    write("ALL/ROADMAP/projects/mobile.md", {
      { "title", "Mobile" },
      { "status", "doing" },
      { "areas", "[ALL]" },
    })
    write("lib.nvim/ROADMAP/plans/lib-mobile.md", {
      { "title", "lib mobile" },
      { "status", "doing" },
      { "project", "ALL/mobile" },
    })
    write("cascade.nvim/ROADMAP/plans/later.md", {
      { "title", "later" },
      { "status", "parked" },
      { "project", "ALL/mobile" },
    })
    F.task(H, root, "lib.nvim", "a", F.meta("A", "open", { { "plan", "lib.nvim/lib-mobile" } }))
    F.task(H, root, "lib.nvim", "b", F.meta("B", "open", { { "plan", "lib.nvim/lib-mobile" } }))
    F.task(H, root, "ALL", "decide", F.meta("Decide", "open", { { "project", "ALL/mobile" } }))
    F.task(H, root, "cascade.nvim", "elsewhere", F.meta("Elsewhere", "open"))
    for _, a in ipairs({ "lib.nvim", "cascade.nvim", "ALL" }) do
      assert(index.write_area(a, o))
    end
  end
  setup_vault()

  -- ── the preview says what the finish would close ──
  local pv = assert(done_flow.preview("lib.nvim/a", o))
  eq(pv.closes_plan, nil, "another member of the plan is open")
  eq(pv.closes_project, nil)
  assert(done_flow.run("lib.nvim/a", o))
  pv = assert(done_flow.preview("lib.nvim/b", o))
  eq(pv.closes_plan, "lib.nvim/lib-mobile")
  eq(pv.closes_project, nil, "the project still has a task of its own")
  pv = assert(done_flow.preview("ALL/decide", o))
  eq(pv.closes_plan, nil)
  eq(pv.closes_project, nil, "a plan of the project is open")

  -- ── the own task of the project first: nothing else closes ──
  local flow = assert(done_flow.run("ALL/decide", o))
  eq(flow.projects_closed, {}, "the plan is still open")
  ok(exists("ALL/ROADMAP/projects/mobile.md"))

  -- ── the last task of the last open plan closes the plan and then the project ──
  pv = assert(done_flow.preview("lib.nvim/b", o))
  eq(pv.closes_plan, "lib.nvim/lib-mobile")
  eq(pv.closes_project, "ALL/mobile", "a parked plan does not hold the project open")
  local doc = assert(require("tasks_nvim.contract").done_preview("lib.nvim/b", { root = root }))
  eq(doc.closes_plan, "lib.nvim/lib-mobile")
  eq(doc.closes_project, "ALL/mobile", "the contract document says so, too")
  flow = assert(done_flow.run("lib.nvim/b", o))
  eq(flow.plans_closed, { "lib.nvim/lib-mobile" })
  eq(flow.projects_closed, { "ALL/mobile" })
  eq(flow.project_summaries["ALL/mobile"].plans, 2, "the finished plan and the parked one")
  eq(flow.project_summaries["ALL/mobile"].tasks, 3)
  eq(flow.project_summaries["ALL/mobile"].parked_left, { "cascade.nvim/later" })
  ok(not exists("ALL/ROADMAP/projects/mobile.md"), "the project file left ROADMAP/projects")
  local files = vim.fn.glob(root .. "/ALL/Backlog/FEATURES/*_mobile.md", false, true)
  eq(#files, 1, "the finished project is in the Backlog")
  has(H.read(files[1]), "status: done")
  has(H.read(root .. "/ALL/Backlog/README.md"), "mobile")
  ok(
    vim.tbl_contains(
      flow.notes,
      "the project ALL/mobile is finished; its parked plan(s) stay: cascade.nvim/later"
    )
  )
  has(
    plan_view.project_closed_text("ALL/mobile", flow.project_summaries["ALL/mobile"]),
    "2 plans, 3 tasks"
  )
  -- the parked plan under a finished project is told by `check`
  assert(index.write_area("lib.nvim", o))
  local codes = {}
  for _, f in ipairs(assert(check.run({ root = root })).findings) do
    codes[#codes + 1] = f.code
  end
  eq(codes, { "plan-project-done" })

  -- ── a project nothing finished is never closed by itself ──
  write("ALL/ROADMAP/projects/empty.md", { { "title", "Empty" }, { "status", "planning" } })
  local res = done_flow.close_projects({ "ALL/empty" }, o)
  eq(res.closed, { "ALL/empty" }, "asked about by name, an empty project may be closed")
  eq(
    done_flow.close_projects({}, o).closed,
    {},
    "but nothing asks about it when no finish names it"
  )
  eq(done_flow.close_projects({ "ALL/ghost" }, o).closed, {}, "an unknown project is ignored")

  -- ── an own task is the last holder ──
  write("ALL/ROADMAP/projects/solo.md", { { "title", "Solo" }, { "status", "doing" } })
  F.task(H, root, "ALL", "solo-task", F.meta("Solo task", "open", { { "project", "ALL/solo" } }))
  assert(index.write_area("ALL", o))
  flow = assert(done_flow.run("ALL/solo-task", o))
  eq(flow.projects_closed, { "ALL/solo" })
  eq(flow.plans_closed, {})

  -- ── a batch closes plan and project once, after the last finish ──
  write("ALL/ROADMAP/projects/pair.md", { { "title", "Pair" }, { "status", "doing" } })
  write("lib.nvim/ROADMAP/plans/pair-plan.md", {
    { "title", "pair plan" },
    { "status", "doing" },
    { "project", "ALL/pair" },
  })
  F.task(H, root, "lib.nvim", "p1", F.meta("P1", "open", { { "plan", "lib.nvim/pair-plan" } }))
  F.task(H, root, "lib.nvim", "p2", F.meta("P2", "open", { { "plan", "lib.nvim/pair-plan" } }))
  F.task(H, root, "ALL", "p3", F.meta("P3", "open", { { "project", "ALL/pair" } }))
  assert(index.write_area("lib.nvim", o))
  assert(index.write_area("ALL", o))
  local many = batch.done_many({ "lib.nvim/p1", "lib.nvim/p2", "ALL/p3" }, o)
  eq(#many.done, 3)
  eq(many.plans_closed, { "lib.nvim/pair-plan" })
  eq(many.projects_closed, { "ALL/pair" })
  eq(many.project_summaries["ALL/pair"].tasks, 3)

  -- ── by hand: plan-close and project-close ──
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(vim.deepcopy(argv), common), {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  write("ALL/ROADMAP/projects/hand.md", { { "title", "Hand" }, { "status", "doing" } })
  write("lib.nvim/ROADMAP/plans/hand-plan.md", {
    { "title", "hand plan" },
    { "status", "doing" },
    { "project", "ALL/hand" },
  })
  F.task(H, root, "lib.nvim", "h1", F.meta("H1", "open", { { "plan", "lib.nvim/hand-plan" } }))
  assert(index.write_area("lib.nvim", o))
  local refused = run({ "plan-close", "lib.nvim/hand-plan" })
  eq(refused.code, 1)
  has(refused.err, "still has 1 open task: lib.nvim/h1")
  ok(exists("lib.nvim/ROADMAP/plans/hand-plan.md"), "a refused close changes nothing")
  eq(run({ "plan-close", "lib.nvim/ghost" }).code, 1)
  eq(run({ "plan-close" }).code, 2)
  refused = run({ "project-close", "ALL/hand" })
  eq(refused.code, 1)
  has(refused.err, "lib.nvim/hand-plan")
  ok(exists("ALL/ROADMAP/projects/hand.md"))

  assert(done_flow.run("lib.nvim/h1", { root = root, today = F.TODAY, chain = false }))
  local closed = run({ "plan-close", "lib.nvim/hand-plan" })
  eq(closed.code, 0, closed.err)
  has(closed.out, "plan-closed\tlib.nvim/hand-plan")
  has(closed.out, "project-closed\tALL/hand")
  ok(not exists("ALL/ROADMAP/projects/hand.md"), "the project followed the plan")

  write("ALL/ROADMAP/projects/manual.md", { { "title", "Manual" }, { "status", "planning" } })
  closed = run({ "project-close", "ALL/manual" })
  eq(closed.code, 0, closed.err)
  has(closed.out, "project-closed\tALL/manual")
  eq(
    run({ "project-close", "ALL/manual" }).code,
    0,
    "closing a finished project again is not an error"
  )

  -- nothing of the above left a project open that should be closed
  eq(#assert(projects.all(o)), 0)
  ok(#assert(scan.open_tasks(o)) >= 1)
end
