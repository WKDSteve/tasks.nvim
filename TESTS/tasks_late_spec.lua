-- TESTS/tasks_late_spec.lua -- a blocker due after the task waiting on it begins: the rule (`tasks_nvim.late`), the
-- `blocker-late` hint of `check` with both ids, and the `late_blockers` of a task entry in `tasks-export/1`.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local late = require("tasks_nvim.late")

  -- ── the rule ──────────────────────────────────────────────────────────────
  local function t(id, fields)
    return vim.tbl_extend(
      "force",
      { id = id, status = "open", blocked_by = {}, after = {} },
      fields or {}
    )
  end
  local by_id = {
    ["a/late"] = t("a/late", { due = "2026-03-10" }),
    ["a/early"] = t("a/early", { due = "2026-02-20" }),
    ["a/undated"] = t("a/undated"),
  }
  local waiting = t("a/w", {
    start = "2026-03-01",
    due = "2026-03-20",
    blocked_by = { "a/late", "a/undated", "a/gone" },
    after = { "a/early", "a/late" },
  })
  eq(late.blockers(waiting, by_id), {
    {
      id = "a/late",
      kind = "blocked_by",
      due = "2026-03-10",
      against = "start",
      date = "2026-03-01",
    },
  }, "late hard blocker once; early, undated and unknown ones are not late")
  -- without a start the due date counts
  local no_start = t("a/n", { due = "2026-03-05", after = { "a/late" } })
  eq(late.blockers(no_start, by_id)[1].against, "due")
  eq(late.blockers(no_start, by_id)[1].kind, "after", "a soft blocker is named as such")
  -- the same day is not late
  eq(#late.blockers(t("a/s", { start = "2026-03-10", blocked_by = { "a/late" } }), by_id), 0)
  -- no date on the waiting task, or parked: nothing
  eq(#late.blockers(t("a/x", { blocked_by = { "a/late" } }), by_id), 0)
  eq(
    #late.blockers(
      t("a/p", { status = "parked", start = "2026-01-01", blocked_by = { "a/late" } }),
      by_id
    ),
    0
  )
  -- of_open: only the tasks that have some
  local map = late.of_open({ by_id["a/late"], waiting })
  eq(vim.tbl_keys(map), { "a/w" })

  -- ── check and the export, on a vault ──────────────────────────────────────
  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "late-one", F.meta("Late one", "open", { { "due", "2026-03-10" } }))
  F.task(
    H,
    root,
    "lib.nvim",
    "waiting-one",
    F.meta(
      "Waiting one",
      "open",
      { { "start", "2026-03-01" }, { "blocked_by", "lib.nvim/late-one" } }
    )
  )
  local report = assert(require("tasks_nvim.check").run({ root = root, today = F.TODAY }))
  local hint
  for _, f in ipairs(report.hints or {}) do
    if f.code == "blocker-late" then
      hint = f
    end
  end
  ok(hint, "check names the late blocker")
  eq(hint.severity, "info", "a hint, never an error")
  eq(hint.id, "lib.nvim/waiting-one")
  has(hint.message, "lib.nvim/late-one")
  has(hint.message, "2026-03-10")
  has(hint.message, "start 2026-03-01")
  for _, f in ipairs(report.findings or {}) do
    ok(f.code ~= "blocker-late", "not among the findings that fail a check")
  end

  local text = require("tasks_nvim.api").call(
    "task",
    '{"params":{"id":"lib.nvim/waiting-one"}}',
    { root = root, today = F.TODAY }
  )
  local doc = vim.json.decode(text)
  eq(doc.task.late_blockers, {
    { id = "lib.nvim/late-one", kind = "blocked_by", due = "2026-03-10", against = "start" },
  })
  local other = vim.json.decode(
    (
      require("tasks_nvim.api").call(
        "task",
        '{"params":{"id":"lib.nvim/late-one"}}',
        { root = root, today = F.TODAY }
      )
    )
  )
  eq(other.task.late_blockers, nil, "a task without late blockers has no field")
end
