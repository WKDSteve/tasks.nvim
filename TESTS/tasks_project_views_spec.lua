-- TESTS/tasks_project_views_spec.lua -- projects on the command line: `projects`, `plans --tree`, the filter `--project=`
-- of `list`, `plan`, `estimate` and `new --project=`.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, has, lacks = H.eq, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local model = require("tasks_nvim.model")
  local scan = require("tasks_nvim.scan")
  local index = require("tasks_nvim.index")

  local root = F.vault(H)
  local function write(path, meta)
    H.write(root .. "/" .. path, F.text(meta))
  end
  write("ALL/ROADMAP/projects/mobile.md", {
    { "title", "Mobile" },
    { "status", "doing" },
    { "areas", "[ALL]" },
    { "phase_order", "[basis, apps]" },
  })
  write("lib.nvim/ROADMAP/plans/lib-mobile.md", {
    { "title", "lib mobile" },
    { "status", "doing" },
    { "project", "ALL/mobile" },
    { "phase", "apps" },
  })
  write("cascade.nvim/ROADMAP/plans/basis.md", {
    { "title", "basis" },
    { "status", "parked" },
    { "project", "ALL/mobile" },
    { "phase", "basis" },
  })
  write("cascade.nvim/ROADMAP/plans/loose.md", { { "title", "loose" }, { "status", "planning" } })
  write("cascade.nvim/Backlog/FEATURES/2026-10-01_old-plan.md", {
    { "title", "old plan" },
    { "status", "done" },
    { "project", "ALL/mobile" },
    { "closed_kind", "plan" },
  })
  write(
    "cascade.nvim/Backlog/TASKS/2026-10-01_old-task.md",
    F.meta("Old task", "done", { { "plan", "cascade.nvim/old-plan" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "a",
    F.meta("A", "open", { { "plan", "lib.nvim/lib-mobile" }, { "effort", "M" } })
  )
  F.task(H, root, "cascade.nvim", "b", F.meta("B", "open", { { "plan", "cascade.nvim/basis" } }))
  F.task(
    H,
    root,
    "ALL",
    "decide",
    F.meta("Decide", "open", { { "project", "ALL/mobile" }, { "effort", "S" } })
  )
  F.task(
    H,
    root,
    "cascade.nvim",
    "other",
    F.meta("Other", "open", { { "plan", "cascade.nvim/loose" } })
  )
  F.task(H, root, "cascade.nvim", "free", F.meta("Free", "open"))
  for _, a in ipairs({ "lib.nvim", "cascade.nvim", "ALL" }) do
    assert(index.write_area(a, { root = root, today = F.TODAY }))
  end

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
  local function lines(text)
    return vim.split(vim.trim(text), "\n", { plain = true })
  end

  -- ── projects ──
  local res = run({ "projects" })
  eq(res.code, 0, res.err)
  eq(#lines(res.out), 1)
  has(res.out, "ALL/mobile\tdoing\troadmap\tMobile\tplans 1/3\ttasks 1/4\t")
  has(res.out, "d open")
  eq(lines(run({ "projects", "ALL" }).out)[1]:match("^[^\t]+"), "ALL/mobile")
  has(
    run({ "projects", "lib.nvim" }).out,
    "ALL/mobile",
    "a project with a plan in the area is listed there"
  )
  eq(vim.trim(run({ "projects", "migrate.nvim" }).out), "", "no project, no plan: nothing")
  eq(run({ "projects", "nowhere.nvim" }).code, 2)

  -- ── plans: unchanged, and as a tree ──
  local flat = lines(run({ "plans" }).out)
  eq(#flat, 3)
  lacks(run({ "plans" }).out, "ALL/mobile\t")
  local tree = lines(run({ "plans", "--tree" }).out)
  eq(tree[1]:match("^[^\t]+"), "ALL/mobile")
  eq(tree[2]:match("^  ([^\t]+)"), "cascade.nvim/basis")
  has(tree[2], "\tstage basis")
  eq(tree[3]:match("^  ([^\t]+)"), "lib.nvim/lib-mobile")
  eq(tree[4]:match("^([^\t]+)"), "cascade.nvim/loose", "a plan of no project follows, not indented")
  eq(#tree, 4)
  -- an area: its plans under the project of another area
  local area_tree = lines(run({ "plans", "lib.nvim", "--tree" }).out)
  eq(
    { area_tree[1]:match("^[^\t]+"), area_tree[2]:match("^  ([^\t]+)") },
    { "ALL/mobile", "lib.nvim/lib-mobile" }
  )
  eq(#area_tree, 2, "the plans of another area stay out")

  -- ── the filter --project= ──
  local function ids(argv)
    local r = run(argv)
    eq(r.code, 0, r.err)
    local out = lines(r.out)
    table.sort(out)
    return out[1] ~= "" and out or {}
  end
  eq(
    ids({ "list", "--project=ALL/mobile", "--format=ids" }),
    { "ALL/decide", "cascade.nvim/b", "lib.nvim/a" },
    "the tasks of its plans and its own"
  )
  eq(ids({ "list", "--project=ALL/ghost", "--format=ids" }), {})
  eq(
    ids({ "list", "--project=ALL/mobile", "--plan=lib.nvim/lib-mobile", "--format=ids" }),
    { "lib.nvim/a" },
    "filters narrow each other"
  )
  eq(run({ "list", "--project=", "--format=ids" }).code, 2, "no value is an error")
  eq(
    ids({ "plan", "--project=ALL/mobile", "--format=ids" }),
    { "ALL/decide", "cascade.nvim/b", "lib.nvim/a" }
  )
  has(run({ "estimate", "--project=ALL/mobile" }).out, "3 tasks")
  -- one project as the scope of `plan`: its head and its stages
  local head = run({ "plan", "--project=ALL/mobile" })
  eq(head.code, 0, head.err)
  has(head.out, "# Plan: project ALL/mobile")
  has(head.out, "**Mobile** (doing)")
  has(head.out, "Stages: basis > apps")
  has(head.out, "3 tasks")
  local ghost = run({ "plan", "--project=ALL/ghost" })
  eq(ghost.code, 1)
  has(ghost.err, "no such open project")
  -- several projects are a filter only, without a head
  lacks(run({ "plan", "--project=ALL/mobile,ALL/other" }).out, "**Mobile**")
  -- a filter built by hand reads the plan files itself
  local open = assert(scan.open_tasks({ root = root }))
  local held = { project = "ALL/mobile", ref_opts = { root = root } }
  eq(#model.filter(open, held), 3)
  -- the filter outlives the files (the dashboard keeps one): a plan that leaves its project leaves the answer, too
  local plan_path = root .. "/cascade.nvim/ROADMAP/plans/basis.md"
  local plan_text = H.read(plan_path)
  local without = plan_text
    :gsub("project: ALL/mobile" .. string.char(10), "")
    :gsub("phase: basis" .. string.char(10), "")
  H.write(plan_path, without)
  eq(#model.filter(open, held), 2, "the filter read the plan files again")
  H.write(plan_path, plan_text)
  eq(#model.filter(open, held), 3)

  -- ── the dashboard: a chip in its header, stored and read back ──
  local core = require("tasks_nvim.ui.dash_core")
  local f = assert(require("tasks_nvim.filter_opts").parse({ project = "ALL/mobile" }))
  eq(core.chips(f), { "project: ALL/mobile" })
  eq(core.filter_to_options(f).project, "ALL/mobile")
  eq(core.filter_from_stored(core.filter_to_options(f)).project, { "ALL/mobile" })
  eq(core.filter_is_empty(f), false)

  -- ── new --project= ──
  local made = run({ "new", "ALL", "Own task", "--project=ALL/mobile", "--phase=basis" })
  eq(made.code, 0, made.err)
  local task = assert(scan.find("ALL/own-task", { root = root }))
  eq({ task.project, task.phase, task.plan }, { "ALL/mobile", "basis", nil })
end
