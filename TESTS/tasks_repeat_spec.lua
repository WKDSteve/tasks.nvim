-- TESTS/tasks_repeat_spec.lua -- routines: `repeat: 8w` on a task, `done` starts the next round (same slug, boxes open
-- again, due and remind moved on), `--last` ends it. Model (interval and date math), check, new/set, done flow, CLI.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local done_flow = require("tasks_nvim.done_flow")
  local scan = require("tasks_nvim.scan")

  -- ── the interval ───────────────────────────────────────────────────────────
  eq({ model.parse_repeat("8w") }, { 8, "w" })
  eq({ model.parse_repeat("999d") }, { 999, "d" })
  for _, bad in ipairs({ "0w", "08w", "1000d", "8", "w", "8x", "8 w", "-8w", "", 8 }) do
    ok(not model.is_repeat(bad), "no interval: " .. tostring(bad))
  end

  -- ── the date math ──────────────────────────────────────────────────────────
  eq(model.add_interval("2026-11-10", 8, "w"), "2027-01-05", "weeks, over the new year")
  eq(model.add_interval("2026-11-10", 1, "d"), "2026-11-11")
  eq(model.add_interval("2026-02-28", 1, "d"), "2026-03-01", "the end of February")
  eq(model.add_interval("2024-02-28", 1, "d"), "2024-02-29", "a leap year has the 29th")
  eq(
    model.add_interval("2026-01-31", 1, "m"),
    "2026-02-28",
    "a month stops at the end of a shorter month"
  )
  eq(model.add_interval("2024-01-31", 1, "m"), "2024-02-29", "also in a leap year")
  eq(model.add_interval("2026-11-30", 3, "m"), "2027-02-28", "months over the year")
  eq(model.add_interval("2026-12-15", 1, "m"), "2027-01-15")
  eq(model.add_interval("2024-02-29", 1, "y"), "2025-02-28", "a leap day, a year on")
  eq(model.add_interval("2024-02-29", 4, "y"), "2028-02-29")
  eq(model.add_interval("not a date", 1, "d"), nil)

  -- the rhythm: from the day it was finished, or from the due date (skipping the rounds that were missed)
  eq(
    model.next_round_due({ repeat_every = "8w", due = "2026-11-01" }, "2026-11-10", "2026-11-10"),
    "2027-01-05",
    "default: from the day of the finish"
  )
  eq(
    model.next_round_due(
      { repeat_every = "8w", repeat_from = "due", due = "2026-11-01" },
      "2026-11-10",
      "2026-11-10"
    ),
    "2026-12-27",
    "from the due date: a fixed rhythm"
  )
  eq(
    model.next_round_due(
      { repeat_every = "8w", repeat_from = "due", due = "2026-11-01" },
      "2027-03-01",
      "2027-03-01"
    ),
    "2027-04-18",
    "a rhythm that fell behind skips the missed rounds"
  )
  eq(
    model.next_round_due({ repeat_every = "1m", repeat_from = "due" }, "2026-03-05", "2026-03-05"),
    "2026-04-05",
    "no due date: from the finish"
  )
  eq(model.next_round_due({ repeat_every = "x" }, "2026-03-05", "2026-03-05"), nil)

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
  local good = parse("due: 2026-03-01\nrepeat: 8w\nrepeat_from: due\n")
  eq(good.repeat_every, "8w")
  eq(good.repeat_from, "due")
  eq(good.valid, true)
  local bad = parse("due: 2026-03-01\nrepeat: often\n")
  ok(vim.tbl_contains(bad.error_codes, "bad-repeat"), table.concat(bad.error_codes, ","))
  eq(bad.valid, false)
  local bad_from = parse("due: 2026-03-01\nrepeat: 8w\nrepeat_from: never\n")
  ok(vim.tbl_contains(bad_from.error_codes, "bad-repeat"), "a bad repeat_from is an error")
  eq(
    hint_codes(parse("repeat: 8w\n")),
    { "repeat-without-due" },
    "a routine without a due date is a warning"
  )
  eq(hint_codes(parse("due: 2026-03-01\nrepeat_from: due\n")), { "repeat-from-without-repeat" })
  eq(hint_codes(parse("due: 2026-03-01\nrepeat: 8w\n")), {})

  -- ── new and set ────────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = "2026-11-10", index = false }
  local function with(extra)
    return vim.tbl_extend("force", o, extra)
  end
  local made = assert(mutate.new(
    "lib.nvim",
    with({
      title = "Reconcile cases",
      due = "2026-11-01",
      repeat_every = "8w",
      repeat_from = "due",
    })
  ))
  local text = H.read(made.path)
  has(text, "repeat: 8w")
  has(text, "repeat_from: due")
  eq(
    select(2, mutate.new("lib.nvim", with({ title = "X", repeat_every = "soon" }))),
    model.repeat_error("soon")
  )
  has(select(2, mutate.new("lib.nvim", with({ title = "Y", repeat_from = "due" }))), "needs repeat")
  has(
    select(2, mutate.new("lib.nvim", with({ title = "Z", repeat_every = "8w", repeat_from = "x" }))),
    "neither done nor due"
  )
  assert(mutate.set(made.id, { ["repeat"] = "2w" }, o))
  has(H.read(made.path), "repeat: 2w")
  has(select(2, mutate.set(made.id, { ["repeat"] = "never" }, o)), "no interval")
  assert(mutate.set(made.id, { ["repeat"] = mutate.REMOVE, repeat_from = mutate.REMOVE }, o))
  ok(not H.read(made.path):find("repeat", 1, true), "taking it away ends the routine")

  -- ── done starts the next round ─────────────────────────────────────────────
  local body = table.concat({
    "",
    "Every eight weeks: compare the open cases.",
    "",
    "## Plan",
    "",
    "- [x] export the list",
    "- [ ] compare",
    "  - [X] nested",
    "",
    "## Akzeptanz",
    "",
    "- [x] nothing is missing",
    "",
  }, "\n")
  local function routine(slug, extra)
    local meta = F.meta("Routine " .. slug, "doing", {
      { "due", "2026-11-01" },
      { "repeat", "8w" },
      { "remind", "2026-11-01" },
      { "blocked_by", "[cascade.nvim/gone]" },
      { "commits", "[repo@aaaaaaa]" },
      { "created", "2026-09-01" },
      { "updated", "2026-09-02" },
    })
    vim.list_extend(meta, extra or {})
    F.task(H, root, "lib.nvim", slug, meta, body)
    return "lib.nvim/" .. slug
  end
  local flow_opts =
    { root = root, today = "2026-11-10", date = "2026-11-10", index = false, pick_next = false }

  local id = routine("sweep")
  local pv = assert(done_flow.preview(id, flow_opts))
  eq(pv.next_round, { due = "2027-01-05" }, "the preview names the next round")
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/sweep.md"), "the preview writes nothing")

  local flow = assert(done_flow.run(id, flow_opts))
  local next_id = "lib.nvim/sweep-2027-01-05"
  eq(flow.next_round.id, next_id, "each round has an id of its own: the slug and the due date")
  eq(flow.next_round.due, "2027-01-05")
  eq(flow.notes, {})
  local finished = assert(scan.find_done(id, { root = root }), "the round is in the Backlog")
  has(finished.path, "2026-11-10_sweep")
  eq(scan.find(id, { root = root }), nil, "the old id is finished, not open (check: duplicate-id)")
  local nxt = assert(scan.find(next_id, { root = root }), "the next round is open")
  eq(nxt.status, "open", "doing becomes open")
  eq(nxt.due, "2027-01-05")
  eq(nxt.remind, "2027-01-05", "the reminder machinery brings it back on its day")
  eq(nxt.repeat_every, "8w", "it is a routine still")
  eq(nxt.created, "2026-11-10")
  eq(nxt.title, "Routine sweep")
  eq(nxt.blocked_by, {}, "what blocked the finished round is met")
  local next_text = H.read(nxt.path)
  ok(not next_text:find("commits", 1, true), "no commits line")
  ok(
    not next_text:find("[x]", 1, true) and not next_text:find("[X]", 1, true),
    "every box is open again"
  )
  has(next_text, "- [ ] export the list")
  has(next_text, "  - [ ] nested")
  has(next_text, "- [ ] nothing is missing")
  has(next_text, "Every eight weeks: compare the open cases.", "the body stays")
  local old_text = H.read(finished.path)
  has(old_text, "- [x] export the list", "the finished round keeps its ticks")
  has(old_text, "status: done")

  -- the next round can be finished again; one more round follows
  local again = assert(
    done_flow.run(
      next_id,
      vim.tbl_extend("force", flow_opts, { today = "2027-01-05", date = "2027-01-05" })
    )
  )
  eq(again.next_round.due, "2027-03-02")
  eq(
    again.next_round.id,
    "lib.nvim/sweep-2027-03-02",
    "the date of the round before is replaced, not piled up"
  )
  local checked = assert(require("tasks_nvim.check").run({ root = root }))
  for _, f in ipairs(checked.findings) do
    ok(f.code ~= "duplicate-id", "no id is open and finished at once: " .. f.message)
  end

  -- `last` ends the routine
  local last_id = routine("ends")
  local last = assert(done_flow.run(last_id, vim.tbl_extend("force", flow_opts, { last = true })))
  eq(last.next_round, nil)
  eq(scan.find(last_id, { root = root }), nil, "no next round after --last")

  -- a task that is no routine is finished as before
  F.task(
    H,
    root,
    "lib.nvim",
    "plain",
    F.meta("Plain", "open", { { "created", "2026-09-01" }, { "updated", "2026-09-02" } }),
    body
  )
  eq(assert(done_flow.run("lib.nvim/plain", flow_opts)).next_round, nil)
  eq(scan.find("lib.nvim/plain", { root = root }), nil)

  -- a fixed rhythm: from the due date, skipping what was missed
  local fixed = assert(done_flow.run(routine("fixed", { { "repeat_from", "due" } }), flow_opts))
  eq(fixed.next_round.due, "2026-12-27")
  eq(fixed.next_round.id, "lib.nvim/fixed-2026-12-27")

  -- a failing next round never undoes the finish: a note says so
  local blocked_id = routine("blocked")
  local in_the_way = root .. "/lib.nvim/ROADMAP/tasks/blocked-2027-01-05.md"
  H.write(in_the_way, "in the way")
  local broken = assert(done_flow.run(blocked_id, flow_opts))
  eq(broken.next_round, nil)
  ok(scan.find_done(blocked_id, { root = root }) ~= nil, "the task is finished")
  has(table.concat(broken.notes, "; "), "the next round of lib.nvim/blocked was not started")
  eq(H.read(in_the_way), "in the way", "nothing is overwritten")

  -- ── the CLI ────────────────────────────────────────────────────────────────
  local cli = require("tasks_nvim.cli")
  local function run(argv)
    local out, err = {}, {}
    local full = vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=2026-11-10" })
    local code = cli.run(full, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  local newed = run({
    "new",
    "cascade.nvim",
    "Monthly cleanup",
    "--due=2026-11-30",
    "--repeat=1m",
    "--slug=cleanup",
  })
  eq(newed.code, 0, newed.err)
  has(H.read(root .. "/cascade.nvim/ROADMAP/tasks/cleanup.md"), "repeat: 1m")
  ok(run({ "new", "cascade.nvim", "Bad", "--repeat=often" }).code ~= 0, "a bad interval is refused")
  local finished_cli = run({ "done", "cascade.nvim/cleanup", "--no-next" })
  eq(finished_cli.code, 0, finished_cli.err)
  has(finished_cli.out, "next-round\tcascade.nvim/cleanup-2026-12-10\t2026-12-10")
  local last_cli = run({ "done", "cascade.nvim/cleanup-2026-12-10", "--last" })
  eq(last_cli.code, 0, last_cli.err)
  ok(not last_cli.out:find("next-round", 1, true), "--last: no next round")
  eq(scan.find("cascade.nvim/cleanup-2026-12-10", { root = root }), nil)
end
