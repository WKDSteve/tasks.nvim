-- TESTS/tasks_plan_compare_spec.lua -- `plan_compare`: the open plans side by side (tasks, effort, path, pace).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local contract = require("tasks_nvim.contract")

  local TODAY = "2026-01-10"
  local root = F.vault(H)
  local area = "lib.nvim"

  ---@param slug string
  ---@param head string
  local function plan_file(slug, head)
    H.write(
      root .. "/" .. area .. "/ROADMAP/plans/" .. slug .. ".md",
      "---\n" .. head .. "\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nA plan.\n"
    )
  end
  ---@param name string   # The file name below `Backlog/TASKS/` (with or without a date).
  ---@param extra string
  local function finished(name, extra)
    H.write(
      root .. "/" .. area .. "/Backlog/TASKS/" .. name .. ".md",
      "---\ntitle: "
        .. name
        .. "\nstatus: done\n"
        .. extra
        .. "\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nDone.\n"
    )
  end

  plan_file("p", "title: Plan P\nstatus: doing\nareas: [lib.nvim]\nphase_order: [one, two]")
  plan_file("q", "title: Plan Q\nstatus: planning\nareas: [lib.nvim]\nphase_order: []")
  -- a chain t2 -> t1 (S then M: the path is 1.5 days), a task without an effort; all of plan p
  F.task(
    H,
    root,
    area,
    "t2",
    F.meta("T2", "open", {
      { "effort", "S" },
      { "plan", "lib.nvim/p" },
      { "phase", "one" },
    })
  )
  F.task(
    H,
    root,
    area,
    "t1",
    F.meta("T1", "open", {
      { "effort", "M" },
      { "plan", "lib.nvim/p" },
      { "phase", "two" },
      { "blocked_by", "[lib.nvim/t2]" },
    })
  )
  F.task(
    H,
    root,
    area,
    "t3",
    F.meta("T3", "open", { { "plan", "lib.nvim/p" }, { "phase", "two" } })
  )
  -- an open task of no plan: in no row
  F.task(H, root, area, "free", F.meta("Free", "open", { { "effort", "XL" } }))
  -- finished members: two in the last week, one the week before, one long ago, one without a date in its name
  finished("2026-01-10_d1", "plan: lib.nvim/p\neffort: S")
  finished("2026-01-09_d2", "plan: lib.nvim/p\neffort: M")
  finished("2026-01-01_d3", "plan: lib.nvim/p")
  finished("2025-12-01_d4", "plan: lib.nvim/p\neffort: 2d")
  finished("undated-d5", "plan: lib.nvim/p")
  -- a finished task of another plan: not counted for p
  finished("2026-01-10_other", "plan: lib.nvim/gone")

  local doc, err = contract.plan_compare({}, { root = root, today = TODAY })
  ok(doc, tostring(err and (err.message or err)))
  eq(doc.kind, "tasks.plan_compare")
  eq(doc.today, TODAY)
  eq(doc.weeks, 4)
  eq(
    vim.tbl_map(function(r)
      return r.id
    end, doc.plans),
    { "lib.nvim/p", "lib.nvim/q" },
    "one row per open plan file, in the order of the vault"
  )

  local p = doc.plans[1]
  eq(p.tasks.open, 3, "open members")
  eq(p.tasks.done, 5, "finished members, the undated one too; another plan's not")
  eq(p.tasks.ready, 2, "t2 and t3 are ready")
  eq(p.tasks.waiting, 1, "t1 waits for t2")
  eq(p.progress, 0.63, "5 of 8, two decimals")
  eq(p.effort.open_days, 1.5, "S + M; the task without an effort adds nothing")
  eq(p.effort.open_without, 1, "the open task without an effort is counted")
  eq(p.effort.done_days, 3.5, "S + M + 2d of the finished ones")
  ok(
    p.effort.open_low <= p.effort.open_days and p.effort.open_days <= p.effort.open_high,
    "the sum lies in its range"
  )
  eq(p.path.days, 1.5, "the chain t2 -> t1")
  eq(p.path.unknown_effort, 0)
  eq(
    p.weekly_done,
    { 0, 0, 1, 2 },
    "oldest week first, the last week ends today; the old one is outside"
  )
  eq(
    p.forecast_weeks,
    { low = 2, high = 4 },
    "3 open: at the best week (2) 2 weeks, at the average (3/4) 4 weeks"
  )
  eq(p.last_done, "2026-01-10")
  eq(p.phase_now, "one", "the first stage that still has an open task")
  eq(p.stages, 2)

  local q = doc.plans[2]
  eq(
    { q.tasks.open, q.tasks.done, q.progress },
    { 0, 0, 0 },
    "a plan without tasks has zeros, no division"
  )
  eq(q.forecast_weeks, nil, "no range from nothing")
  eq(q.phase_now, nil)
  eq(q.weekly_done, { 0, 0, 0, 0 })

  -- `ids` narrows it; an id that is no open plan is refused by name
  local only =
    assert(contract.plan_compare({ ids = { "lib.nvim/q" } }, { root = root, today = TODAY }))
  eq(#only.plans, 1)
  eq(only.plans[1].id, "lib.nvim/q")
  local none, nerr = contract.plan_compare(
    { ids = { "lib.nvim/nope" } },
    { root = root, today = TODAY }
  )
  eq(none, nil)
  eq(nerr.code, "invalid_argument")
  ok(nerr.message:find("lib.nvim/nope", 1, true), "the error names the id")

  -- nothing finished in the last weeks: no forecast even with open tasks
  local later =
    assert(contract.plan_compare({ ids = { "lib.nvim/p" } }, { root = root, today = "2026-03-01" }))
  eq(later.plans[1].weekly_done, { 0, 0, 0, 0 })
  eq(later.plans[1].forecast_weeks, nil)

  -- through the dispatcher, with the engine's `today`
  local text = require("tasks_nvim.api").call("plan_compare", nil, { root = root, today = TODAY })
  ok(text:find('"kind":"tasks.plan_compare"', 1, true), "the method answers through the API")
end
