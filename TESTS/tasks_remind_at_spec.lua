-- TESTS/tasks_remind_at_spec.lua -- `remind_at: HH:MM`, the hour a reminder of its `remind` day is sent: the model
-- (a time of day, a time without a day), set (on an open and a finished task; taking the day away takes the time
-- with it; a time without a day is refused), reopen (drops both) and the contract (task entries and `reminders`).

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local contract = require("tasks_nvim.contract")

  -- ── a time of day ──────────────────────────────────────────────────────────
  for _, good in ipairs({ "00:00", "08:00", "14:30", "23:59", "19:05" }) do
    ok(model.is_time(good), "a time: " .. good)
  end
  for _, bad in ipairs({ "24:00", "8:00", "08:60", "08:00:00", "0800", "", "noon", 800 }) do
    ok(not model.is_time(bad), "no time: " .. tostring(bad))
  end

  -- ── the frontmatter ────────────────────────────────────────────────────────
  local function parse(front)
    return model.parse_text(
      "---\ntitle: A\nstatus: open\n" .. front .. "created: 2026-01-01\n---\n\nBody.\n",
      { path = "/v/a/ROADMAP/tasks/a.md", area = "a" }
    )
  end
  local function hint_codes(task)
    local out = {}
    for _, h in ipairs(task.hints) do
      out[#out + 1] = h.code
    end
    return out
  end
  local good = parse("remind: 2026-11-20\nremind_at: 14:30\n")
  eq({ good.remind, good.remind_at, good.valid }, { "2026-11-20", "14:30", true })
  eq(hint_codes(good), {})
  local bad = parse("remind: 2026-11-20\nremind_at: 2pm\n")
  ok(vim.tbl_contains(bad.error_codes, "bad-time"), table.concat(bad.error_codes, ","))
  eq(bad.valid, false)
  eq(
    hint_codes(parse("remind_at: 08:00\n")),
    { "remind-at-without-remind" },
    "a time without a day is a warning"
  )

  -- ── set ────────────────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = "2026-11-10", index = false }
  local made =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Call the bank" })))
  has(
    select(2, mutate.set(made.id, { remind_at = "09:15" }, o)),
    "needs a remind day",
    "a time without a day is refused"
  )
  has(select(2, mutate.set(made.id, { remind = "2026-11-20", remind_at = "9:15" }, o)), "HH:MM")
  assert(mutate.set(made.id, { remind = "2026-11-20", remind_at = "09:15" }, o))
  has(H.read(made.path), "remind_at: 09:15")
  assert(mutate.set(made.id, { remind_at = "17:45" }, o), "a time beside a day already there")
  has(H.read(made.path), "remind_at: 17:45")

  -- the contract carries it, on the task entry
  local doc = assert(contract.task(made.id, { root = root }))
  eq({ doc.task.remind, doc.task.remind_at }, { "2026-11-20", "17:45" })

  -- taking the day away takes the time with it
  assert(mutate.set(made.id, { remind = mutate.REMOVE }, o))
  local text = H.read(made.path)
  ok(not text:find("remind", 1, true), "neither remind nor remind_at is left:\n" .. text)

  -- ── a finished task: set takes remind and remind_at, reopen drops both ─────
  local fin =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Renew the licence" })))
  assert(mutate.done(fin.id, vim.tbl_extend("force", o, { yes = true })))
  assert(
    mutate.set(fin.id, { remind = "2026-12-01", remind_at = "08:30" }, o),
    "a reminder on a finished task, with its hour"
  )
  eq(
    (mutate.set(fin.id, { remind_at = "08:30", title = "Other" }, o)),
    nil,
    "anything else on a finished task is refused"
  )
  local snap = assert(contract.snapshot({ root = root }))
  local found
  for _, r in ipairs(snap.reminders or {}) do
    if r.id == fin.id then
      found = r
    end
  end
  eq(
    found and { found.remind, found.remind_at },
    { "2026-12-01", "08:30" },
    "reminders carry the hour"
  )
  assert(mutate.reopen(fin.id, vim.tbl_extend("force", o, { status = "open" })))
  local reopened = assert(require("tasks_nvim.scan").find(fin.id, { root = root }))
  eq(
    { reopened.remind, reopened.remind_at },
    { nil, nil },
    "reopening drops the reminder and its hour"
  )
end
