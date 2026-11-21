-- TESTS/tasks_milestones_spec.lua -- milestones (`<area>/ROADMAP/milestones/<slug>.md`): `milestone_new` and
-- `milestone_set` through the write door (refused members, inverse, reaching by hand), the engine reaching a milestone
-- when its last member is finished (`done`, `plan_close`, `path_close`, `meeting_close`) and opening it again when a
-- member is reopened (`reached` stays), `close: manual`, the documents `milestones` / `milestone` with their progress,
-- and the `check` rules (unknown, foreign, nested, overlapping members, id taken, drift, overdue).
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local ops_mod = require("tasks_nvim.ops")
  local scan = require("tasks_nvim.scan")
  local mutate = require("tasks_nvim.mutate")
  local fsio = require("tasks_nvim.fsio")
  local milestones = require("tasks_nvim.milestones")

  local root = F.vault(H)
  local TODAY = F.TODAY
  local function run(list, dry)
    local doc, err = ops_mod.run(
      { ops = list, dry_run = dry or nil },
      { root = root, today = TODAY }
    )
    assert(doc, vim.inspect(err))
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    return doc.results[1]
  end
  local function call(method, params)
    local text = api.call(method, { params = params or {} }, { root = root, today = TODAY })
    return vim.json.decode(text)
  end
  local function token(id)
    local t = assert(scan.find(id, { root = root }), id)
    return mutate.confirm_token(id, fsio.etag(assert(fsio.read(t.path))))
  end
  local function done(id)
    return run({ { op = "done", id = id, confirm = token(id) } })
  end
  local function file_of(id)
    local area, slug = id:match("^([^/]+)/(.+)$")
    return root .. "/" .. area .. "/ROADMAP/milestones/" .. slug .. ".md"
  end
  local function check()
    local res = assert(require("tasks_nvim.check").run({ root = root, today = TODAY }))
    local by = {}
    for _, f in ipairs(res.findings) do
      by[f.code] = by[f.code] or {}
      table.insert(by[f.code], f)
    end
    return by
  end

  local hello = call("hello")
  for _, cap in ipairs({ "milestones", "milestone_new", "milestone_set" }) do
    ok(vim.tbl_contains(hello.capabilities, cap), cap)
  end

  F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "open"))
  F.task(H, root, "lib.nvim", "beta", F.meta("Beta", "open"))
  F.task(H, root, "cascade.nvim", "gamma", F.meta("Gamma", "open"))

  -- ── milestone_new: members are ids of this vault ─────────────────────────────
  local unknown = run({
    { op = "milestone_new", area = "lib.nvim", title = "R1", includes = { "lib.nvim/nope" } },
  })
  eq(unknown.ok, false, vim.inspect(unknown))
  eq(unknown.error.code, "invalid_argument")
  has(unknown.error.message, "exists nowhere")
  local foreign = run({
    {
      op = "milestone_new",
      area = "lib.nvim",
      title = "R1",
      includes = { "tricentis-vault/Learning/x" },
    },
  })
  eq(foreign.ok, false)
  has(foreign.error.message, "another vault")
  local bad_due =
    run({ { op = "milestone_new", area = "lib.nvim", title = "R1", due = "12.12.2026" } })
  eq(bad_due.ok, false)
  has(bad_due.error.message, "due is not a date")

  local dry = run({
    {
      op = "milestone_new",
      area = "lib.nvim",
      title = "Release 1",
      due = "2026-12-15",
      includes = { "lib.nvim/alpha", "lib.nvim/beta", "lib.nvim/alpha" },
    },
  }, true)
  eq(dry.outcome, "would_create", vim.inspect(dry))
  eq(dry.id, "lib.nvim/release-1")
  ok(not fsio.is_file(file_of("lib.nvim/release-1")), "a dry run writes nothing")
  local made = run({
    {
      op = "milestone_new",
      area = "lib.nvim",
      title = "Release 1",
      due = "2026-12-15",
      includes = { "lib.nvim/alpha", "lib.nvim/beta", "lib.nvim/alpha" },
    },
  })
  eq(made.outcome, "created", vim.inspect(made))
  local text = H.read(file_of("lib.nvim/release-1"))
  has(text, "status: doing\n")
  has(text, "due: 2026-12-15\n")
  has(text, "includes: [lib.nvim/alpha, lib.nvim/beta]\n", "each member once")
  has(text, "## Verlauf\n")
  -- the id namespace is shared: a task cannot take the slug
  local taken = run({ { op = "new", area = "lib.nvim", title = "Release 1" } })
  eq(taken.id, "lib.nvim/release-1-2", vim.inspect(taken))
  run({ { op = "set", id = "lib.nvim/release-1-2", patch = { status = "parked" } } })

  -- ── reached by the last finish, opened again by a reopen ─────────────────────
  local first = done("lib.nvim/alpha")
  eq(first.outcome, "done", vim.inspect(first))
  eq(first.milestones_reached, nil, "one member is still open")
  local last = done("lib.nvim/beta")
  eq(last.milestones_reached, { "lib.nvim/release-1" }, vim.inspect(last))
  ok(vim.tbl_contains(last.changed_ids, "lib.nvim/release-1"), "the milestone file was written")
  text = H.read(file_of("lib.nvim/release-1"))
  has(text, "status: done\n")
  has(text, "reached: " .. TODAY .. "\n")
  has(text, "- " .. TODAY .. " reached\n")

  local reopened = run({ { op = "reopen", id = "lib.nvim/beta" } })
  eq(reopened.outcome, "changed", vim.inspect(reopened))
  eq(reopened.milestones_reopened, { "lib.nvim/release-1" })
  text = H.read(file_of("lib.nvim/release-1"))
  has(text, "status: doing\n")
  has(text, "reached: " .. TODAY .. "\n", "reached stays as its history")
  has(text, "opened again: lib.nvim/beta is open")
  local again = done("lib.nvim/beta")
  eq(again.milestones_reached, { "lib.nvim/release-1" }, "reached a second time")

  -- decision 2026-11-21: a complete milestone of close: auto is not kept open by hand
  local keep_open =
    run({ { op = "milestone_set", id = "lib.nvim/release-1", patch = { status = "doing" } } })
  eq(keep_open.ok, false, vim.inspect(keep_open))
  eq(keep_open.error.code, "invalid_argument")
  eq(keep_open.error.details.hint, "set close: manual to keep it open")
  has(H.read(file_of("lib.nvim/release-1")), "status: done\n", "nothing written")
  local manual_open = run({
    {
      op = "milestone_set",
      id = "lib.nvim/release-1",
      patch = { status = "doing", close = "manual" },
    },
  })
  eq(manual_open.outcome, "changed", "with close: manual it may be opened")
  eq(manual_open.milestones_reached, nil, "and stays open")

  -- ── close: manual ────────────────────────────────────────────────────────────
  F.task(H, root, "lib.nvim", "delta", F.meta("Delta", "open"))
  local manual = run({
    {
      op = "milestone_new",
      area = "lib.nvim",
      title = "Handabnahme",
      close = "manual",
      includes = { "lib.nvim/delta" },
    },
  })
  eq(manual.outcome, "created")
  has(H.read(file_of("lib.nvim/handabnahme")), "close: manual\n")
  local early =
    run({ { op = "milestone_set", id = "lib.nvim/handabnahme", patch = { status = "done" } } })
  eq(early.ok, false, "refused while a member is open")
  eq(early.error.details.holding, { "lib.nvim/delta" }, vim.inspect(early))
  local d = done("lib.nvim/delta")
  eq(d.milestones_reached, nil, "close: manual is not reached by the engine")
  has(H.read(file_of("lib.nvim/handabnahme")), "status: doing\n")
  local by_hand =
    run({ { op = "milestone_set", id = "lib.nvim/handabnahme", patch = { status = "done" } } })
  eq(by_hand.outcome, "changed", vim.inspect(by_hand))
  eq(by_hand.inverse.op, "milestone_set")
  eq(by_hand.inverse.patch, { status = "doing" })
  text = H.read(file_of("lib.nvim/handabnahme"))
  has(text, "reached: " .. TODAY .. "\n")
  has(text, "reached (closed by hand)")
  eq(
    call("milestone", { id = "lib.nvim/handabnahme" }).milestone.summary,
    "",
    "a line of the history is no summary"
  )
  local unknown_key =
    run({ { op = "milestone_set", id = "lib.nvim/handabnahme", patch = { reached = TODAY } } })
  eq(unknown_key.ok, false, "reached is the engine's")

  -- ── plans, paths and meetings as members ─────────────────────────────────────
  eq(run({ { op = "plan_new", area = "lib.nvim", title = "Umbau" } }).outcome, "created")
  F.task(
    H,
    root,
    "lib.nvim",
    "umbau-1",
    F.meta("Umbau 1", "open", { { "plan", "lib.nvim/umbau" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "umbau-2",
    F.meta("Umbau 2", "open", { { "plan", "lib.nvim/umbau" } })
  )
  eq(run({ { op = "path_new", area = "lib.nvim", title = "Lua lernen" } }).outcome, "created")
  eq(
    run({
      {
        op = "meeting_new",
        area = "lib.nvim",
        title = "Abnahme",
        fields = { date = "2026-10-20" },
      },
    }).outcome,
    "created"
  )
  local mixed = run({
    {
      op = "milestone_new",
      area = "lib.nvim",
      title = "Gemischt",
      due = "2026-10-01",
      includes = {
        "lib.nvim/umbau",
        "lib.nvim/lua-lernen",
        "lib.nvim/abnahme-2026-10-20",
        "cascade.nvim/gamma",
      },
    },
  })
  eq(mixed.outcome, "created", vim.inspect(mixed))

  -- the documents: progress counts a plan by its tasks, the others as one each
  local list = call("milestones")
  eq(list.kind, "tasks.milestones", vim.inspect(list))
  local entry
  for _, item in ipairs(list.items) do
    if item.id == "lib.nvim/gemischt" then
      entry = item
    end
  end
  ok(entry, vim.inspect(list.items))
  eq(entry.progress, { members = 4, members_done = 0, done = 0, total = 5 }, vim.inspect(entry))
  eq(entry.overdue, true, "due before today and not reached")
  eq(entry.close, "auto")
  local doc = call("milestone", { id = "lib.nvim/gemischt" })
  eq(doc.kind, "tasks.milestone", vim.inspect(doc))
  local kinds = {}
  for _, m in ipairs(doc.members) do
    kinds[m.id] = m.kind .. ":" .. m.state
  end
  eq(kinds, {
    ["lib.nvim/umbau"] = "plan:open",
    ["lib.nvim/lua-lernen"] = "path:open",
    ["lib.nvim/abnahme-2026-10-20"] = "meeting:open",
    ["cascade.nvim/gamma"] = "task:open",
  })
  eq(call("milestone", { id = "lib.nvim/none" }).code, "not_found")
  eq(#call("milestones", { area = "cascade.nvim" }).items, 0, "an area without milestones")

  -- check: overdue while open
  local by = check()
  ok(by["milestone-overdue"], vim.inspect(vim.tbl_keys(by)))

  eq(done("lib.nvim/umbau-1").milestones_reached, nil)
  local plan_done = done("lib.nvim/umbau-2")
  eq(plan_done.plans_closed, { "lib.nvim/umbau" }, vim.inspect(plan_done))
  eq(plan_done.milestones_reached, nil, "three members are open")
  eq(run({ { op = "path_close", id = "lib.nvim/lua-lernen" } }).milestones_reached, nil)
  eq(done("cascade.nvim/gamma").milestones_reached, nil)
  local meeting =
    run({ { op = "meeting_close", id = "lib.nvim/abnahme-2026-10-20", result = "Abgenommen." } })
  eq(meeting.ok, true, vim.inspect(meeting))
  eq(meeting.milestones_reached, { "lib.nvim/gemischt" }, "the last member was the meeting")
  entry = call("milestone", { id = "lib.nvim/gemischt" }).milestone
  eq(entry.status, "done")
  eq(entry.reached, TODAY)
  eq(entry.overdue, false)
  eq(entry.progress, { members = 4, members_done = 4, done = 5, total = 5 })

  -- ── check ────────────────────────────────────────────────────────────────────
  local function milestone_file(slug, includes, extra)
    H.write(
      file_of("cascade.nvim/" .. slug),
      F.text(
        vim.list_extend({
          { "title", slug },
          { "status", "doing" },
          { "includes", "[" .. table.concat(includes, ", ") .. "]" },
        }, extra or {}),
        "\n## Verlauf\n"
      )
    )
  end
  milestone_file("lost", { "cascade.nvim/nowhere" })
  milestone_file("abroad", { "other-vault:cascade.nvim/x" })
  milestone_file("nested", { "lib.nvim/gemischt" })
  F.task(H, root, "lib.nvim", "eps", F.meta("Eps", "open", { { "plan", "lib.nvim/plan-b" } }))
  eq(run({ { op = "plan_new", area = "lib.nvim", title = "Plan B" } }).outcome, "created")
  milestone_file("twice", { "lib.nvim/plan-b", "lib.nvim/eps" })
  milestone_file("pending", { "lib.nvim/alpha" })
  milestone_file("bad-close", { "lib.nvim/alpha" }, { { "close", "sometimes" } })
  milestone_file("alpha", { "lib.nvim/eps" })
  H.write(root .. "/cascade.nvim/ROADMAP/tasks/alpha.md", F.text(F.meta("Clash", "open")))
  by = check()
  local function codes_of(code)
    local out = {}
    for _, f in ipairs(by[code] or {}) do
      out[#out + 1] = f.id
    end
    table.sort(out)
    return out
  end
  eq(codes_of("milestone-include-unknown"), { "cascade.nvim/lost" }, vim.inspect(by))
  eq(codes_of("milestone-include-foreign"), { "cascade.nvim/abroad" })
  eq(codes_of("milestone-nested"), { "cascade.nvim/nested" })
  eq(codes_of("milestone-include-overlap"), { "cascade.nvim/twice" })
  eq(codes_of("milestone-drift"), { "cascade.nvim/pending" })
  eq(codes_of("milestone-bad-close"), { "cascade.nvim/bad-close" })
  eq(codes_of("milestone-id-taken"), { "cascade.nvim/alpha" })
  eq((by["milestone-include-unknown"] or {})[1].severity, "error")
  eq((by["milestone-include-overlap"] or {})[1].severity, "warn")
  eq((by["milestone-drift"] or {})[1].severity, "warn")

  -- the engine settles the pending one with the next write that can finish something
  local res = milestones.settle({ root = root, today = TODAY })
  ok(vim.tbl_contains(res.reached, "cascade.nvim/pending"), vim.inspect(res))
  ok(not vim.tbl_contains(res.reached, "cascade.nvim/lost"), "a missing member holds it open")

  -- ── the command line ─────────────────────────────────────────────────────────
  local cli = require("tasks_nvim.cli")
  local function tasks(argv)
    local out, err = {}, {}
    vim.list_extend(argv, { "--vault=" .. root, "--today=" .. TODAY })
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  F.task(H, root, "cascade.nvim", "omega", F.meta("Omega", "open"))
  local refused =
    tasks({ "milestone-new", "cascade.nvim", "Nirgends", "--includes=cascade.nvim/nowhere" })
  eq(refused.code, 2, vim.inspect(refused))
  has(refused.err, "milestone-include-unknown")
  local cli_made = tasks({
    "milestone-new",
    "cascade.nvim",
    "Omega fertig",
    "--due=2026-11-01",
    "--includes=cascade.nvim/omega",
  })
  eq(cli_made.code, 0, vim.inspect(cli_made))
  has(cli_made.out, "created\tcascade.nvim/omega-fertig\t")
  local listed = tasks({ "milestones", "cascade.nvim" })
  has(listed.out, "cascade.nvim/omega-fertig\tdoing\t2026-11-01\t0/1\tOmega fertig\n")
  local cli_done = tasks({ "done", "cascade.nvim/omega" })
  eq(cli_done.code, 0, vim.inspect(cli_done))
  has(cli_done.out, "milestone-reached\tcascade.nvim/omega-fertig\n")
end
