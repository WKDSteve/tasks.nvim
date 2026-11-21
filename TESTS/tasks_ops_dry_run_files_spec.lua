-- TESTS/tasks_ops_dry_run_files_spec.lua -- a dry run of tasks-ops/1 sees the plans and projects an earlier
-- `plan_new`/`project_new` of the same request would create: the dry run answers what the real run does.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, has = H.eq, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "open", { { "prio", "2" } }))

  ---@param list table[]
  ---@param dry boolean
  ---@return table[] results
  local function run(list, dry)
    local text = api.call(
      "ops",
      vim.json.encode({ ops = list, dry_run = dry }),
      { root = root, today = F.TODAY }
    )
    local doc = vim.json.decode(text)
    eq(doc.kind, "tasks.result", text)
    return doc.results
  end

  ---The same request as a dry run, then for real: the same `ok` values and ids, op for op.
  ---@param name string
  ---@param list table[]
  ---@return table[] dry
  ---@return table[] real
  local function same(name, list)
    local dry = run(list, true)
    local real = run(list, false)
    eq(#dry, #real, name .. ": as many results")
    for i = 1, #real do
      eq(
        dry[i].ok,
        real[i].ok,
        ("%s: op %d ok (dry %s / real %s)"):format(
          name,
          i,
          vim.inspect(dry[i].error),
          vim.inspect(real[i].error)
        )
      )
      eq(dry[i].id, real[i].id, ("%s: op %d id"):format(name, i))
    end
    return dry, real
  end

  -- a plan, and a task of it in one of its stages
  local dry = same("plan and task", {
    { op = "plan_new", area = "lib.nvim", title = "Rollout", phases = { "build", "close" } },
    {
      op = "new",
      area = "lib.nvim",
      title = "Rollout target",
      fields = { plan = "lib.nvim/rollout", phase = "close" },
    },
  })
  eq(dry[2].ok, true, vim.inspect(dry[2]))
  eq(dry[2].outcome, "would_create")
  eq(assert(scan.find("lib.nvim/rollout-target", { root = root })).plan, "lib.nvim/rollout")

  -- a stage the new plan does not have is still refused, in the dry run as in the real one
  dry = same("plan and a wrong phase", {
    { op = "plan_new", area = "lib.nvim", title = "Second", phases = { "build" } },
    {
      op = "new",
      area = "lib.nvim",
      title = "Second target",
      fields = { plan = "lib.nvim/second", phase = "nowhere" },
    },
  })
  eq(dry[2].ok, false)
  has(dry[2].error.message, "is not in the phase_order of lib.nvim/second")

  -- a project, and a task in one of its stages
  dry = same("project and task", {
    { op = "project_new", area = "lib.nvim", title = "Launch", phases = { "basis", "apps" } },
    {
      op = "new",
      area = "lib.nvim",
      title = "Launch task",
      fields = { project = "lib.nvim/launch", phase = "apps" },
    },
  })
  eq(dry[2].ok, true, vim.inspect(dry[2]))

  -- a project, and a plan in one of its stages
  dry = same("project and plan", {
    { op = "project_new", area = "lib.nvim", title = "Program", phases = { "one", "two" } },
    {
      op = "plan_new",
      area = "lib.nvim",
      title = "Program plan",
      project = "lib.nvim/program",
      phase = "two",
    },
  })
  eq(dry[2].ok, true, vim.inspect(dry[2]))

  -- set: an open task moves into a plan the same request makes
  dry = same("plan and set", {
    { op = "plan_new", area = "lib.nvim", title = "Adopt", phases = { "a", "b" } },
    { op = "set", id = "lib.nvim/alpha", patch = { plan = "lib.nvim/adopt", phase = "b" } },
  })
  eq(dry[2].ok, true, vim.inspect(dry[2]))

  -- a plan that is a project is no plan: the kind counts
  dry = same("project named as plan", {
    { op = "project_new", area = "lib.nvim", title = "Kind check" },
    {
      op = "new",
      area = "lib.nvim",
      title = "Kind check task",
      fields = { plan = "lib.nvim/kind-check" },
    },
  })
  eq(dry[2].ok, false)
  has(dry[2].error.message, "is no plan file")

  -- a bare [[slug]] names the pending plan or project as the real run's link index does
  dry = same("wikilinks to pending files", {
    { op = "project_new", area = "lib.nvim", title = "Linked program", phases = { "x" } },
    {
      op = "plan_new",
      area = "lib.nvim",
      title = "Linked plan",
      phases = { "p" },
      project = "[[linked-program]]",
      phase = "x",
    },
    {
      op = "new",
      area = "lib.nvim",
      title = "Linked task",
      fields = { plan = "[[linked-plan]]", phase = "p" },
    },
  })
  eq(dry[2].ok, true, vim.inspect(dry[2]))
  eq(dry[3].ok, true, vim.inspect(dry[3]))
end
