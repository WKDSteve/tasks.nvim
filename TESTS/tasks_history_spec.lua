-- TESTS/tasks_history_spec.lua -- the series of the overview figures: rows are written when the figures changed, read
-- back as levels, merged from two machines without a conflict, a broken line is named and skipped, and the past is
-- filled from the repository of the vault.
-- @scans-data

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local cli = require("tasks_nvim.cli")
  local contract = require("tasks_nvim.contract")
  local history = require("tasks_nvim.history")
  local backfill = require("tasks_nvim.history_backfill")

  ---@param root string
  ---@param area string
  ---@param slug string
  ---@param status string
  ---@param extra? table[]
  local function task(root, area, slug, status, extra)
    local meta = F.meta("Task " .. slug, status, extra)
    meta[#meta + 1] = { "created", "2026-03-02" }
    meta[#meta + 1] = { "updated", "2026-03-02" }
    return F.task(H, root, area, slug, meta)
  end

  ---@param root string
  ---@return Tasks.ContractView
  local function view_of(root)
    local view, err = contract.view({ root = root })
    ok(view, tostring(err))
    return view
  end

  ---@param root string
  ---@param name string
  ---@return string[]
  local function lines(root, name)
    local text = H.read(root .. "/" .. history.DIR .. "/" .. name)
    local out = vim.split(text, "\n", { plain = true })
    if out[#out] == "" then
      out[#out] = nil
    end
    return out
  end

  ---@param root string
  ---@param params? table
  ---@param today? string
  ---@return table doc
  ---@return string text
  local function call(root, params, today)
    local text = api.call(
      "history",
      params and vim.json.encode({ params = params }) or nil,
      { root = root, today = today or "2026-03-10" }
    )
    return vim.json.decode(text), text
  end

  -- ── the figures of a view ──────────────────────────────────────────────────
  local root = F.vault(H)
  task(root, "lib.nvim", "alpha", "open", { { "effort", "S" }, { "value", "3" } })
  task(root, "lib.nvim", "beta", "open", { { "blocked_by", "lib.nvim/alpha" }, { "value", "5" } })
  task(root, "lib.nvim", "gamma", "parked", { { "effort", "2d" } })
  task(root, "cascade.nvim", "delta", "doing", { { "effort", "M" } })

  local figures = history.figures(view_of(root))
  local lib = figures["lib.nvim"]
  eq(lib.open, 3, "three open tasks in lib.nvim")
  eq({ lib.status.open, lib.status.parked, lib.status.doing }, { 2, 1, 0 }, "by status")
  eq({ lib.state.ready, lib.state.waiting, lib.state.parked }, { 1, 1, 1 }, "by readiness")
  eq({ lib.with_value, lib.value }, { 2, 8 }, "two tasks carry a value, 3 + 5")
  eq(lib.with_effort, 2, "two tasks carry an effort")
  ok(lib.days > 2, "S and 2d add up to more than two days: " .. lib.days)
  eq(figures["cascade.nvim"].status.doing, 1)
  eq(figures["ALL"].open, 0, "an area without an open task has zeros")
  eq(figures["_Telemetry"], nil, "the folder of the series is no area")

  -- ── the series grows: a row per area whose figures changed ─────────────────
  eq(history.exists(root), false, "no series before the first row")
  local dry = history.record(view_of(root), { today = "2026-03-02", dry_run = true })
  eq(dry.rows, 2, "a dry run says what it would write")
  eq(history.exists(root), false, "and writes nothing")

  local first = history.record(view_of(root), { today = "2026-03-02", at = "2026-03-02T08:00:00Z" })
  eq(first.rows, 2, "the two areas with figures get a row, the empty ones none")
  eq(first.areas, { "cascade.nvim", "lib.nvim" })
  eq(first.file, "_Telemetry/history/2026-03.jsonl", "the file is named relative to the vault")
  eq(#lines(root, "2026-03.jsonl"), 2)
  lacks(H.read(root .. "/" .. first.file), root, "a row holds no path of this machine")

  local again = history.record(view_of(root), { today = "2026-03-02", at = "2026-03-02T09:00:00Z" })
  eq(again.rows, 0, "unchanged figures write nothing")
  local next_day =
    history.record(view_of(root), { today = "2026-03-03", at = "2026-03-03T09:00:00Z" })
  eq(next_day.rows, 0, "nor does another day with the same figures")
  eq(#lines(root, "2026-03.jsonl"), 2)

  -- a change on a later day: one more row, of the area that changed only
  task(root, "cascade.nvim", "epsilon", "open", {})
  local grown = history.record(view_of(root), { today = "2026-03-05", at = "2026-03-05T09:00:00Z" })
  eq(grown.areas, { "cascade.nvim" })
  eq(#lines(root, "2026-03.jsonl"), 3, "the series grew by one row")

  -- a second change on the same day replaces the row of that day: at most one row per day and area
  task(root, "cascade.nvim", "zeta", "open", {})
  local same_day =
    history.record(view_of(root), { today = "2026-03-05", at = "2026-03-05T17:00:00Z" })
  eq(same_day.rows, 1)
  eq(#lines(root, "2026-03.jsonl"), 3, "the row of the day was replaced, not added")

  -- a new month is a new file
  task(root, "ALL", "eta", "open", {})
  local april = history.record(view_of(root), { today = "2026-04-01", at = "2026-04-01T09:00:00Z" })
  eq(april.file, "_Telemetry/history/2026-04.jsonl")
  eq(april.areas, { "ALL" })

  -- ── read back: levels, gaps, carried days ───────────────────────────────────
  local doc, text = call(root, { since = "2026-02-28", ["until"] = "2026-03-06" })
  eq(doc.kind, "tasks.history")
  eq({ doc.since, doc["until"], doc.resolution }, { "2026-02-28", "2026-03-06", "day" })
  eq(
    { doc.first, doc.last },
    { "2026-03-02", "2026-04-01" },
    "the first and the last day with a row"
  )
  eq(#doc.points, 7, "one point per day")
  lacks(text, root, "no path of this machine in the document")
  local by_day = {}
  for _, p in ipairs(doc.points) do
    by_day[p.day] = p
  end
  eq(by_day["2026-03-01"].open, nil, "a day before the first row has no level (unknown, never 0)")
  eq(by_day["2026-03-01"].recorded, false)
  eq(by_day["2026-03-02"].open, 4, "the sum over the areas")
  eq(by_day["2026-03-02"].recorded, true)
  eq(by_day["2026-03-02"].by_state.ready, 2)
  eq(by_day["2026-03-02"].with_value, 2)
  eq(by_day["2026-03-02"].created, 7, "what the files say: seven tasks were created on that day")
  eq(by_day["2026-03-03"].open, 4, "a day without a row carries the level over")
  eq(by_day["2026-03-03"].recorded, false, "and says that nothing was written on it")
  eq(by_day["2026-03-05"].open, 6, "the level after the change")
  eq(by_day["2026-03-06"].by_status.open, 4)

  -- one area only; a group or an area nobody knows
  local one = call(root, { area = "cascade.nvim", since = "2026-03-02", ["until"] = "2026-03-05" })
  eq(one.points[1].open, 1)
  eq(one.points[4].open, 3)
  eq(one.area, "cascade.nvim")
  eq(
    call(root, { area = "ALL", since = "2026-03-02", ["until"] = "2026-03-05" }).first,
    "2026-04-01"
  )
  eq(call(root, { area = "nope.nvim" }).code, "not_found", "an unknown area is refused")

  -- weeks: named by the Monday, the level of the last day, the sums of what the files say
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-03-04_shipped.md",
    "---\ntitle: Shipped\nstatus: done\ncreated: 2026-03-03\nupdated: 2026-03-04\n---\n\nDone.\n"
  )
  local weeks = call(root, { since = "2026-03-01", ["until"] = "2026-03-10", resolution = "week" })
  eq(#weeks.points, 3, "three weeks touch the window")
  eq(weeks.points[1].day, "2026-02-23", "the Monday of the first week, before the window")
  eq(weeks.points[1].open, nil, "its last day in the window has no level yet")
  eq(weeks.points[2].day, "2026-03-02")
  eq(weeks.points[2].open, 6, "the level of the last day of the week")
  eq(weeks.points[2].recorded, true)
  eq(weeks.points[2].done, 1, "one task was finished in that week")
  eq(weeks.points[2].created, 8)
  eq(weeks.points[3].recorded, false)

  -- the window: defaults and what is refused
  local default = call(root, nil, "2026-03-10")
  eq({ default.since, default["until"] }, { "2025-12-11", "2026-03-10" }, "the last 90 days")
  eq(#default.points, 90)
  for _, bad in ipairs({
    { since = "yesterday" },
    { ["until"] = "2026-13-01" },
    { since = "2026-03-02", ["until"] = "2026-03-01" },
    { resolution = "month" },
    { since = "2020-01-01", ["until"] = "2026-03-01" },
    { colour = "red" },
  }) do
    local refused = call(root, bad)
    eq(refused.code, "invalid_argument", "refused: " .. vim.inspect(bad))
  end
  eq(
    #call(root, { since = "2020-01-01", ["until"] = "2026-03-01", resolution = "week" }).points,
    322,
    "six years fit as weeks"
  )

  -- ── two machines: both wrote the same day, the files merge by union ─────────
  local two = F.vault(H)
  task(two, "lib.nvim", "alpha", "open", {})
  history.record(view_of(two), { today = "2026-03-02", at = "2026-03-02T08:00:00Z" })
  local base = H.read(two .. "/_Telemetry/history/2026-03.jsonl")
  -- machine one adds a task in the morning, machine two another two in the evening, both from the same base
  task(two, "lib.nvim", "beta", "open", {})
  history.record(view_of(two), { today = "2026-03-03", at = "2026-03-03T08:00:00Z" })
  local one_text = H.read(two .. "/_Telemetry/history/2026-03.jsonl")
  H.write(two .. "/_Telemetry/history/2026-03.jsonl", base)
  task(two, "lib.nvim", "gamma", "open", {})
  history.record(view_of(two), { today = "2026-03-03", at = "2026-03-03T19:00:00Z" })
  local two_text = H.read(two .. "/_Telemetry/history/2026-03.jsonl")
  ok(one_text ~= two_text, "the two machines wrote different rows for the day")
  -- what `merge=union` makes of it: the lines of both sides, in either order
  local function union(a, b)
    local seen, out = {}, {}
    for _, t in ipairs({ a, b }) do
      for _, line in ipairs(vim.split(t, "\n", { plain = true, trimempty = true })) do
        if not seen[line] then
          seen[line] = true
          out[#out + 1] = line
        end
      end
    end
    return table.concat(out, "\n") .. "\n"
  end
  for _, merged in ipairs({ union(one_text, two_text), union(two_text, one_text) }) do
    H.write(two .. "/_Telemetry/history/2026-03.jsonl", merged)
    local read = history.read(two)
    eq(read.problems, {}, "a merged file has no broken line")
    eq(#read.rows, 2, "one row per day and area is left")
    eq(read.rows[2].at, "2026-03-03T19:00:00Z", "the later row of the day wins, whatever the order")
    eq(read.rows[2].open, 3)
  end
  -- the next row written for that day leaves one line of it in the file
  task(two, "lib.nvim", "delta", "open", {})
  history.record(view_of(two), { today = "2026-03-03", at = "2026-03-03T20:00:00Z" })
  eq(#lines(two, "2026-03.jsonl"), 2, "both rows of the day were replaced by one")

  -- ── a broken line is named and skipped, by the reader ───────────────────────
  local good = lines(two, "2026-03.jsonl")
  local huge = good[2]:gsub('"open":%d+', '"open":1e300')
  local negative = good[2]:gsub('"with_value":%d+', '"with_value":-1')
  local other_month = good[2]:gsub('"day":"2026%-03%-03"', '"day":"2026-05-03"')
  local unknown_word = good[2]:gsub('"status":{', '"status":{"frozen":2,')
  H.write(two .. "/_Telemetry/history/2026-03.jsonl", table.concat({
    good[1],
    "<<<<<<< HEAD",
    "{not json",
    huge,
    negative,
    other_month,
    unknown_word,
    '{"v":2,"day":"2026-03-03","area":"lib.nvim"}',
    ("x"):rep(history.MAX_LINE + 1),
    "",
    good[2],
  }, "\n") .. "\n")
  local broken = history.read(two)
  eq(#broken.rows, 2, "the two good rows are still the series")
  eq(#broken.problems, 8, "every broken line is named: " .. vim.inspect(broken.problems))
  has(broken.problems[1], "_Telemetry/history/2026-03.jsonl:2: ", "by file and line")
  has(table.concat(broken.problems, "\n"), "open is no count")
  has(table.concat(broken.problems, "\n"), "day is not of this month")
  has(table.concat(broken.problems, "\n"), "line too long")
  lacks(table.concat(broken.problems, "\n"), two, "no path of this machine in a problem")
  local with_broken, broken_text = call(two, { since = "2026-03-02", ["until"] = "2026-03-03" })
  eq(with_broken.kind, "tasks.history", "the document is still an answer")
  eq(#with_broken.incomplete, 8, "and names what it skipped")
  eq(with_broken.points[2].open, 4)
  lacks(broken_text, two)
  -- the writer keeps a line it cannot read: it may be a row of a newer engine
  task(two, "lib.nvim", "epsilon", "open", {})
  history.record(view_of(two), { today = "2026-03-04", at = "2026-03-04T08:00:00Z" })
  has(H.read(two .. "/_Telemetry/history/2026-03.jsonl"), '{"v":2,"day":"2026-03-03"')
  -- many broken lines: the first ones are named, the rest is counted
  local many = {}
  for i = 1, history.MAX_PROBLEMS + 5 do
    many[i] = "garbage " .. i
  end
  H.write(two .. "/_Telemetry/history/2026-02.jsonl", table.concat(many, "\n") .. "\n")
  local flood = history.read(two).problems
  eq(#flood, history.MAX_PROBLEMS + 1)
  has(flood[#flood], "more")
  vim.fn.delete(two .. "/_Telemetry/history/2026-02.jsonl")

  -- an area that is gone gets a row of zeros, so its last level does not stay in the sum for ever
  local gone = F.vault(H)
  task(gone, "lib.nvim", "alpha", "open", {})
  task(gone, "cascade.nvim", "beta", "open", {})
  history.record(view_of(gone), { today = "2026-03-02", at = "2026-03-02T08:00:00Z" })
  vim.fn.delete(gone .. "/cascade.nvim", "rf")
  local after = history.record(view_of(gone), { today = "2026-03-03", at = "2026-03-03T08:00:00Z" })
  eq(after.areas, { "cascade.nvim" })
  eq(call(gone, { since = "2026-03-02", ["until"] = "2026-03-03" }).points[2].open, 1)

  -- ── the command line ────────────────────────────────────────────────────────
  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, errs = {}, {}
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        errs[#errs + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(errs) }
  end

  local cv = F.vault(H)
  task(cv, "lib.nvim", "alpha", "open", { { "value", "4" } })
  local flags = { "--vault=" .. cv, "--today=2026-03-02" }
  -- `index` only adds to a series that exists: a vault that keeps none gets no new folder from it
  local indexed = run(vim.list_extend({ "index" }, flags))
  eq(indexed.code, 0, indexed.err)
  lacks(indexed.out, "history\t")
  eq(history.exists(cv), false, "index does not start a series")
  local rec = run(vim.list_extend({ "history", "record" }, flags))
  eq(rec.code, 0, rec.err)
  has(rec.out, "history\t1 row(s)\t_Telemetry/history/2026-03.jsonl")
  -- from now on a run over the whole vault writes down the day
  task(cv, "lib.nvim", "beta", "open", {})
  local later = { "--vault=" .. cv, "--today=2026-03-03" }
  eq(run(vim.list_extend({ "index", "lib.nvim" }, later)).out:find("history\t", 1, true), nil)
  eq(#lines(cv, "2026-03.jsonl"), 1, "the index of one area writes no row")
  eq(run(vim.list_extend({ "index", "--no-history" }, later)).out:find("history\t", 1, true), nil)
  local whole = run(vim.list_extend({ "index" }, later))
  has(whole.out, "history\t1 row(s)")
  eq(#lines(cv, "2026-03.jsonl"), 2)
  eq(run(vim.list_extend({ "index", "--check" }, later)).out:find("history\t", 1, true), nil)

  local shown = run({
    "history",
    "--since=2026-03-01",
    "--until=2026-03-03",
    "--vault=" .. cv,
    "--today=2026-03-03",
  })
  eq(shown.code, 0, shown.err)
  local rows = vim.split(shown.out, "\n", { plain = true, trimempty = true })
  has(rows[1], "# day\trecorded\topen\tready")
  has(rows[2], "2026-03-01\t-\t-\t-", "a day before the first row")
  has(rows[3], "2026-03-02\t*\t1\t1")
  has(rows[4], "2026-03-03\t*\t2\t2")
  local as_json = run({ "history", "lib.nvim", "--format=json", "--vault=" .. cv })
  eq(vim.json.decode(as_json.out).kind, "tasks.history")
  eq(run({ "history", "--resolution=year", "--vault=" .. cv }).code, 2, "a bad request is exit 2")
  eq(run({ "history", "record", "extra", "--vault=" .. cv }).code, 2)

  -- ── the operation of the write door (what a hub sends) ──────────────────────
  local ov = F.vault(H)
  task(ov, "lib.nvim", "alpha", "open", {})
  ---@param request table
  ---@return table
  local function ops(request)
    return vim.json.decode(
      (api.call("ops", vim.json.encode(request), { root = ov, today = "2026-03-02" }))
    )
  end
  local would = ops({ dry_run = true, ops = { { op = "history_record" } } })
  eq(would.ok, true, vim.inspect(would))
  eq({ would.results[1].outcome, would.results[1].rows }, { "would_change", 1 })
  eq(history.exists(ov), false, "a dry run writes nothing")
  local did = ops({ ops = { { op = "history_record" } } })
  eq({ did.results[1].outcome, did.results[1].rows }, { "changed", 1 })
  eq(did.results[1].file, "_Telemetry/history/2026-03.jsonl")
  eq(ops({ ops = { { op = "history_record" } } }).results[1].outcome, "unchanged")
  local with_field = ops({ ops = { { op = "history_record", id = "lib.nvim/alpha" } } })
  ok(
    with_field.kind == "tasks.error" or with_field.results[1].ok == false,
    "the operation takes no field: " .. vim.inspect(with_field)
  )
  ok(vim.list_contains(contract.hello({ root = ov }).capabilities, "history"))

  -- ── the past, from the repository of the vault ──────────────────────────────
  if vim.fn.executable("git") ~= 1 then
    return
  end
  local gv = F.vault(H)
  ---@param args string[]
  ---@param date? string
  ---@return string stdout
  local function git(args, date)
    local cmd = { "git", "-C", gv, "-c", "user.name=t", "-c", "user.email=t@example.org" }
    vim.list_extend(cmd, args)
    local env = date and { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } or nil
    local res = vim.system(cmd, { text = true, env = env }):wait()
    eq(res.code, 0, "git " .. table.concat(args, " ") .. ": " .. tostring(res.stderr))
    return res.stdout or ""
  end
  ---@param date string
  local function commit(date)
    git({ "add", "-A" })
    git({ "commit", "-q", "-m", "state of " .. date }, date)
  end
  git({ "init", "-q" })
  git({ "config", "core.autocrlf", "false" })
  task(gv, "lib.nvim", "alpha", "open", { { "value", "2" } })
  commit("2026-03-02T09:00:00")
  task(gv, "lib.nvim", "beta", "open", { { "blocked_by", "lib.nvim/alpha" } })
  commit("2026-03-02T15:00:00")
  -- a day without a commit (03-03), then a day that changes another area
  task(gv, "cascade.nvim", "gamma", "doing", {})
  commit("2026-03-04T12:00:00")
  -- a day with a commit that changes no figure
  H.write(gv .. "/README.md", "notes\n")
  commit("2026-03-05T12:00:00")
  task(gv, "lib.nvim", "delta", "open", {})
  commit("2026-03-06T12:00:00")
  -- today: uncommitted work in the tree, which a backfill must leave alone
  task(gv, "lib.nvim", "uncommitted", "open", {})
  local head, status = git({ "rev-parse", "HEAD" }), git({ "status", "--porcelain" })

  local days = backfill.days(gv)
  eq(#days, 4, "four days have a commit")
  eq(days[1].day, "2026-03-02")
  local tried = backfill.run({ root = gv, today = "2026-03-06", dry_run = true })
  eq({ tried.days, tried.rows }, { 3, 2 }, "a dry run: the days before today, two rows")
  eq(history.exists(gv), false)

  local filled, ferr = backfill.run({ root = gv, today = "2026-03-06" })
  ok(filled, tostring(ferr))
  eq({ filled.days, filled.rows, filled.kept }, { 3, 2, 0 })
  eq({ filled.first, filled.last }, { "2026-03-02", "2026-03-05" })
  eq(filled.skipped, {})
  eq(git({ "rev-parse", "HEAD" }), head, "the repository is where it was")
  eq(
    git({ "status", "--porcelain", "--", ".", ":(exclude)_Telemetry" }),
    status,
    "and so is its tree, but for the series"
  )
  ok(
    H.exists(gv .. "/lib.nvim/ROADMAP/tasks/uncommitted.md"),
    "the uncommitted task is still there"
  )
  local git_rows = history.read(gv).rows
  eq(#git_rows, 2, "the day without a change of figures got no row")
  eq({ git_rows[1].day, git_rows[1].area, git_rows[1].open }, { "2026-03-02", "lib.nvim", 2 })
  eq(
    git_rows[1].state.waiting,
    1,
    "counted from the last commit of the day, with the engine of today"
  )
  eq(git_rows[1].src, "git", "a row from the repository says so")
  eq({ git_rows[2].day, git_rows[2].area }, { "2026-03-04", "cascade.nvim" })
  has(H.read(gv .. "/_Telemetry/history/2026-03.jsonl"), '"src":"git"')

  -- a second run finds every day filled or unchanged; a day that has a row is never counted again
  local second = backfill.run({ root = gv, today = "2026-03-06" })
  eq({ second.rows, second.kept }, { 0, 2 })
  -- a row written on its day stays: the count from git never replaces it
  history.record(view_of(gv), { today = "2026-03-06", at = "2026-03-06T18:00:00Z" })
  local third = backfill.run({ root = gv, today = "2026-03-07" })
  eq({ third.rows, third.kept }, { 0, 3 })
  local final = call(gv, { since = "2026-03-01", ["until"] = "2026-03-06" }, "2026-03-06")
  local opens = {}
  for _, p in ipairs(final.points) do
    opens[#opens + 1] = p.open == nil and "-" or p.open
  end
  eq(opens, { "-", 2, 2, 3, 3, 5 }, "the curve: unknown, two, carried, three, carried, today")

  -- a window, and what is refused
  local windowed = F.vault(H)
  eq(backfill.run({ root = windowed, today = "2026-03-06" }), nil, "a vault that is no repository")
  local bad_day, bad_err = backfill.run({ root = gv, since = "soon" })
  eq(bad_day, nil)
  has(bad_err, "since must be a day")

  -- the command line form
  local cmd = run({ "history", "backfill", "--dry-run", "--vault=" .. gv, "--today=2026-03-07" })
  eq(cmd.code, 0, cmd.err)
  -- the day whose commit changed no figure has no row, so it is counted again (and again writes nothing)
  has(cmd.out, "backfill\t1 day(s)\t0 row(s) (dry run)\t2026-03-05..2026-03-05\t3 day(s) with rows")
end
