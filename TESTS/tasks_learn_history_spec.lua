-- TESTS/tasks_learn_history_spec.lua -- the series of the learning figures (`learn_history`, `tasks.learn_history`,
-- `tasks learn history`): a row per day and path only when its figures changed, written by `history.record` (so by
-- `history record`, `index` and the operation `history_record`), a finished path kept, a broken line skipped; the
-- differences per step (a path's first row on the first day is where it starts, a later one counts from nothing), no
-- step before the first day, the streak, the days of levels and rewards, the pace; `learn_next` ordered by the last
-- active day. The document itself is the golden `learn-history`.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local G = dofile(here .. "/contract_golden.lua")
  local api = require("tasks_nvim.api")
  local cli = require("tasks_nvim.cli")
  local contract = require("tasks_nvim.contract")
  local history = require("tasks_nvim.history")
  local lh = require("tasks_nvim.learn_history")

  -- ── rows ──────────────────────────────────────────────────────────────────
  local row = {
    day = "2026-01-02",
    path = "a/p",
    area = "a",
    at = "2026-01-02T10:00:00Z",
    learned = 1,
    seen = 0,
    dropped = 0,
    open = 2,
    total = 3,
    xp = 10,
    done_h = 1.5,
    level = 1,
    reached = { "1" },
  }
  local line = lh.encode_row(row)
  local back = assert(lh.parse_row(line))
  eq(back.learned, 1)
  eq(back.done_h, 1.5)
  eq(back.reached, { "1" })
  eq(back.given, nil)
  local function bad(patch)
    local obj = vim.json.decode(line)
    for k, v in pairs(patch) do
      obj[k] = v
    end
    return select(2, lh.parse_row(vim.json.encode(obj)))
  end
  ok(bad({ v = 2 }))
  ok(bad({ day = "gestern" }))
  ok(bad({ path = "kein-id" }))
  ok(bad({ learned = -1 }))
  ok(bad({ xp = 1.5 }))
  ok(bad({ reached = { "x" } }))
  ok(bad({ at = "2026-01-02" }))
  eq(select(2, lh.parse_row("{")), "no JSON object")

  -- steps
  eq(lh.week_start("2026-01-07"), "2026-01-05", "a Wednesday's Monday")
  eq(lh.step_start("2026-02-17", "month"), "2026-02-01")
  eq(lh.next_step("2026-12-01", "month"), "2027-01-01")
  eq(lh.next_step("2026-01-05", "week"), "2026-01-12")

  -- ── writing ───────────────────────────────────────────────────────────────
  local root = F.vault(H)
  G.write_learn_paths(root)
  local function record(today)
    local view = assert(contract.view({ root = root }))
    return assert(history.record(view, { today = today, at = today .. "T09:00:00Z" }))
  end
  local r1 = record("2026-02-01")
  eq(r1.learn_rows, 5, "every path with a tree, the parked and the finished one too")
  eq(r1.learn_file, "_Telemetry/history/learn-2026-02.jsonl")
  local r2 = record("2026-02-02")
  eq(r2.learn_rows, 0, "nothing changed: no row")
  local file = root .. "/lib.nvim/ROADMAP/paths/signale.md"
  H.write(file, (H.read(file):gsub("%- %[ %] SIGTERM", "- [x] SIGTERM")))
  local r3 = record("2026-02-03")
  eq(r3.learn_rows, 1, "the one path that changed")
  local text = H.read(root .. "/_Telemetry/history/learn-2026-02.jsonl")
  has(text, '"day":"2026-02-03"')
  eq(#vim.split(vim.trim(text), "\n"), 6)
  -- a second run of the same day replaces its row
  H.write(file, (H.read(file):gsub("%- %[ %] Ergebnis", "- [x] Ergebnis")))
  eq(record("2026-02-03").learn_rows, 1)
  eq(#vim.split(vim.trim(H.read(root .. "/_Telemetry/history/learn-2026-02.jsonl")), "\n"), 6)
  -- the operation of the hub says so, a dry run writes nothing
  H.write(file, (H.read(file):gsub("%- %[x%] SIGTERM", "- [ ] SIGTERM")))
  local res = vim.json.decode((api.call("ops", {
    client_op_id = "h",
    dry_run = true,
    ops = { { op = "history_record" } },
  }, { root = root, today = "2026-02-04" })))
  eq(res.results[1].learn_rows, 1, vim.inspect(res))
  eq(res.results[1].outcome, "would_change")
  eq(#vim.split(vim.trim(H.read(root .. "/_Telemetry/history/learn-2026-02.jsonl")), "\n"), 6)

  -- ── the document ──────────────────────────────────────────────────────────
  local root2 = F.vault(H)
  G.write_learn_paths(root2)
  G.write_learn_series(root2)
  local function call(params, today)
    local t = api.call(
      "learn_history",
      { params = params or {} },
      { root = root2, today = today or "2026-01-06" }
    )
    local doc = vim.json.decode(t)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end
  ok(
    vim.tbl_contains(
      vim.json.decode((api.call("hello", {}, { root = root2 }))).capabilities,
      "learn_history"
    )
  )
  local d = call({ since = "2026-01-01", ["until"] = "2026-01-06" })
  eq(d.first, "2026-01-02")
  eq(d.points[1].date, "2026-01-02", "no step before the first day of the series")
  eq(#d.points, 5)
  eq(d.points[1].learned, 0, "the first row on the first day is where it starts")
  eq(d.points[4].learned, 2)
  eq(
    d.points[4].paths[2].learned,
    1,
    "a path that appears later counts from nothing: 0 on its first day"
  )
  eq(d.streak, { current = 1, longest = 1, last_day = "2026-01-05" })
  eq(d.paths[1].levels, { { ref = "1", reached_on = "2026-01-03" } })
  eq(d.paths[1].rewards, { { ref = "1", given_on = "2026-01-05" } })
  eq(#d.incomplete, 1, "the broken line is named")
  -- weeks and months sum the days
  local w = call({ since = "2026-01-01", ["until"] = "2026-01-11", step = "week" })
  eq(
    vim.tbl_map(function(p)
      return p.date .. ":" .. p.learned .. ":" .. p.days
    end, w.points),
    { "2025-12-29:1:1", "2026-01-05:2:1" }
  )
  local m = call({ since = "2026-01-01", ["until"] = "2026-01-31", step = "month" })
  eq(#m.points, 1)
  eq(m.points[1].xp, 25)
  eq(m.points[1].done_h, 3.5)
  -- the streak keeps today when yesterday was a learning day, and breaks after
  eq(call({}, "2026-01-06").streak.current, 1)
  eq(call({}, "2026-01-07").streak.current, 0)
  -- the scope
  eq(#call({ paths = { "lib.nvim/signale" } }).paths, 1)
  eq(#call({ areas = { "cascade.nvim" } }).points, 0, "no row in scope: no step at all, never 0")
  eq(call({ areas = { "cascade.nvim" } }).first, nil)
  -- the pace and the forecast, once the series reaches four weeks back
  local far = call({ since = "2026-01-28", ["until"] = "2026-01-30" }, "2026-01-30")
  local proz = far.paths[1]
  eq(proz.pace, { points = 0.75, hours = 0.88 }, "3 points and 3.5 hours over 4 weeks")
  eq(proz.forecast_weeks.points, 7, "5 open points of the file at 0.75 a week")
  ok(proz.forecast_weeks.hours_min ~= nil)
  -- the refusals
  eq(select(2, call({ step = "year" })), "invalid_argument")
  eq(select(2, call({ since = "2026-02-01", ["until"] = "2026-01-01" })), "invalid_argument")
  eq(select(2, call({ since = "gestern" })), "invalid_argument")
  eq(select(2, call({ since = "2000-01-01", ["until"] = "2026-01-01" })), "invalid_argument")
  eq(select(2, call({ areas = { "nope" } })), "not_found")

  -- the last active day in one pass: a long series of a path costs no lookup per row (it was quadratic: 0.5 s for
  -- 60 paths over three years)
  do
    local list, n = {}, 0
    local day = "2024-01-01"
    while day <= "2024-12-31" do
      n = n + 1
      list[#list + 1] = {
        day = day,
        path = "a/p",
        area = "a",
        at = day .. "T00:00:00Z",
        learned = n,
        seen = 0,
        dropped = 0,
        open = 0,
        total = 400,
        xp = 0,
        done_h = 0,
      }
      day = require("tasks_nvim.model").add_days(day, 1)
    end
    list[#list + 1] = vim.tbl_extend("force", list[#list], { day = "2025-01-01" })
    local calls, real_at = 0, lh.at
    lh.at = function(...)
      calls = calls + 1
      return real_at(...)
    end
    local active = lh.last_active(list, "2024-01-01", "2025-06-30")
    lh.at = real_at
    eq(active, "2024-12-31", "the last row changed nothing")
    eq(calls, 0, "no lookup per row")
    eq(lh.last_active(list, "2024-01-01", "2024-01-01"), nil, "the first day is where it starts")
    eq(
      lh.last_active(list, "2023-12-01", "2024-01-01"),
      "2024-01-01",
      "a path that appears later counts"
    )
  end

  -- the row of a day: a binary search over the rows of a path (the windows ask it for every day and path)
  do
    local reads = 0
    local list = {}
    local day = "2024-01-01"
    for i = 1, 1024 do
      list[i] = setmetatable({}, {
        __index = function(_, k)
          if k == "day" then
            reads = reads + 1
            return rawget(list, -i)
          end
        end,
      })
      rawset(list, -i, day)
      day = require("tasks_nvim.model").add_days(day, 2)
    end
    eq(lh.at(list, "2023-12-31"), nil, "before the first row")
    eq(lh.at(list, "2024-01-01"), list[1])
    eq(lh.at(list, "2024-01-02"), list[1], "a day between two rows: the one before")
    eq(lh.at(list, "2024-01-03"), list[2])
    eq(lh.at(list, "2099-01-01"), list[1024], "after the last row")
    reads = 0
    lh.at(list, "2025-06-01")
    ok(reads <= 12, ("%d reads of a day for 1024 rows: no linear search"):format(reads))
  end

  -- learn_next: the path active last first (from the series), before the one updated last
  local nxt = vim.json.decode((api.call("learn_next", { params = {} }, { root = root2 })))
  eq(nxt.items[1].path, "lib.nvim/prozesse")

  -- ── the command line ──────────────────────────────────────────────────────
  local function run(argv)
    local out, err = {}, {}
    vim.list_extend(argv, { "--vault=" .. root2, "--today=2026-01-06" })
    local c = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return c, vim.trim(table.concat(out, "\n")), table.concat(err, "\n")
  end
  local c, out, err = run({ "learn", "history", "--since=2026-01-01", "--until=2026-01-06" })
  eq(c, 0, err)
  has(out, "# since 2026-01-02, streak 1 (longest 1)")
  has(out, "2026-01-05\t2\t1\t0\t20\t1.5\t1")
  has(err, "warn: skipped _Telemetry/history/learn-2026-01.jsonl:6")
  eq((run({ "learn", "history", "--step=year" })), 2)
end
