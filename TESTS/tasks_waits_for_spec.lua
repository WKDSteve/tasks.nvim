-- TESTS/tasks_waits_for_spec.lua -- `waits_for`: why a task is parked. The field (model, check), the coupling with
-- `status` in every write (set, new, the dashboard's status cycle, done, reopen, the write door), the filter, the
-- overview (`waits`), the release of a key, and where the reason is shown (next, the plan, the index, the dashboard).

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local batch = require("tasks_nvim.batch")
  local check = require("tasks_nvim.check")
  local cli = require("tasks_nvim.cli")
  local dash = require("tasks_nvim.ui.dash_core")
  local filter_opts = require("tasks_nvim.filter_opts")
  local index = require("tasks_nvim.index")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local next_pick = require("tasks_nvim.next_pick")
  local plan = require("tasks_nvim.plan")
  local plan_view = require("tasks_nvim.plan_view")
  local scan = require("tasks_nvim.scan")
  local waits = require("tasks_nvim.waits")

  local TODAY = F.TODAY

  ---@param meta table[]
  ---@param slug? string
  ---@param area? string
  ---@return Tasks.Task
  local function parse(meta, slug, area)
    area = area or "a"
    return model.parse_text(F.text(meta), {
      path = "/v/" .. area .. "/ROADMAP/tasks/" .. (slug or "t") .. ".md",
      area = area,
      location = "roadmap",
    })
  end

  ---@param t Tasks.Task
  ---@param code string
  ---@return boolean
  local function has_hint(t, code)
    for _, h in ipairs(t.hints) do
      if h.code == code then
        return true
      end
    end
    return false
  end

  ---@param list Tasks.Task[]
  ---@return string[]
  local function slugs(list)
    local out = {}
    for _, t in ipairs(list) do
      out[#out + 1] = t.slug
    end
    return out
  end

  -- ── the key ─────────────────────────────────────────────────────────────
  for _, key in ipairs({ "mac", "budget-2027", "0day", ("a"):rep(40) }) do
    ok(model.is_waits_for(key), key .. " is a key")
  end
  for _, bad in ipairs({ "Mac", "a_b", "-mac", "two words", "", ("a"):rep(41), "none", "mac,ios" }) do
    ok(not model.is_waits_for(bad), "'" .. bad .. "' is no key")
  end
  ok(not model.is_waits_for(nil))
  ok(not model.is_waits_for(7))

  -- ── model: the field, the error, the warning ────────────────────────────
  local parked = parse(F.meta("P", "parked", { { "waits_for", "mac" } }))
  ok(parked.valid, vim.inspect(parked.errors))
  eq(parked.waits_for, "mac")
  eq(#parked.hints, 0, "a parked task with a reason is what the field is for")

  local by_choice = parse(F.meta("C", "parked"))
  ok(by_choice.valid, "parked without a reason stays valid")
  eq(by_choice.waits_for, nil)
  eq(#by_choice.hints, 0)

  local wrong = parse(F.meta("W", "parked", { { "waits_for", "My Mac" } }))
  ok(not wrong.valid, "a value that is no key is an error")
  eq(wrong.error_codes, { "invalid-waits-for" })
  has(wrong.errors[1], "invalid waits_for 'My Mac'")

  local astray = parse(F.meta("A", "open", { { "waits_for", "mac" } }))
  ok(astray.valid, "a reason on a task that is not parked is only a warning")
  ok(has_hint(astray, "waits-for-without-parked"))
  local broken_and_astray = parse(F.meta("B", "open", { { "waits_for", "My Mac" } }))
  ok(
    not has_hint(broken_and_astray, "waits-for-without-parked"),
    "one finding for a bad key, not two"
  )

  -- ── new ─────────────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  ---@param title string
  ---@param extra? table
  ---@param area? string
  local function new(title, extra, area)
    return assert(
      mutate.new(area or "lib.nvim", vim.tbl_extend("force", o, { title = title }, extra or {}))
    )
  end
  ---@param id string
  ---@return Tasks.Task
  local function find(id)
    return assert(scan.find(id, { root = root }))
  end

  local mac1 = new("Port to mac", { waits_for = "mac" })
  eq(find(mac1.id).status, "parked", "a task that names what it waits for is created parked")
  eq(find(mac1.id).waits_for, "mac")
  has(
    H.read(mac1.path),
    "status: parked\nwaits_for: mac\n",
    "the reason stands right below the status"
  )
  local _, new_err = mutate.new(
    "lib.nvim",
    vim.tbl_extend("force", o, { title = "No", status = "open", waits_for = "mac" })
  )
  has(new_err, "waits_for goes with status parked, not open")
  local _, key_err =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "No", waits_for = "My Mac" }))
  has(key_err, "invalid waits_for 'My Mac'")
  ok(
    not H.exists(root .. "/lib.nvim/ROADMAP/tasks/no.md"),
    "nothing is created for a refused reason"
  )
  lacks(H.read(new("Plain").path), "waits_for", "a task without a reason has no such line")
  lacks(mutate.template({ today = TODAY }), "waits_for", "the template does not offer the key")

  -- ── set: the reason and the status move together ────────────────────────
  ok(vim.tbl_contains(mutate.SETTABLE, "waits_for"))
  local t1 = new("Needs a licence")
  local set1 = assert(mutate.set(t1.id, { waits_for = "licence" }, o))
  ok(set1.changed)
  eq(find(t1.id).status, "parked", "giving a reason parks the task in the same write")
  eq(find(t1.id).waits_for, "licence")
  eq(set1.before, { waits_for = mutate.REMOVE, status = "open" }, "the inverse names both keys")

  local set2 = assert(
    mutate.set(t1.id, { status = "doing" }, vim.tbl_extend("force", o, { today = "2026-10-04" }))
  )
  eq(find(t1.id).status, "doing")
  eq(find(t1.id).waits_for, nil, "leaving parked drops the reason in the same write")
  lacks(H.read(t1.path), "waits_for")
  eq(find(t1.id).updated, "2026-10-04")
  eq(set2.before, { status = "parked", waits_for = "licence" }, "and the inverse brings it back")
  assert(mutate.set(t1.id, set2.before, o))
  eq({ find(t1.id).status, find(t1.id).waits_for }, { "parked", "licence" }, "the inverse applied")

  assert(mutate.set(t1.id, { status = "parked" }, o))
  eq(find(t1.id).waits_for, "licence", "setting parked again keeps the reason")
  assert(mutate.set(t1.id, { waits_for = "mac" }, o))
  eq(
    { find(t1.id).status, find(t1.id).waits_for },
    { "parked", "mac" },
    "a parked task takes another reason"
  )
  assert(mutate.set(t1.id, { waits_for = mutate.REMOVE }, o))
  eq(
    { find(t1.id).status, find(t1.id).waits_for },
    { "parked" },
    "removing the reason leaves it parked by choice"
  )

  local _, both_err = mutate.set(t1.id, { status = "open", waits_for = "mac" }, o)
  has(both_err, "waits_for goes with status parked, not open")
  local _, bad_err = mutate.set(t1.id, { waits_for = "My Mac" }, o)
  has(bad_err, "invalid waits_for 'My Mac'")
  local _, none_err = mutate.set(t1.id, { waits_for = "none" }, o)
  has(none_err, "invalid waits_for 'none'", "`none` is the filter word, never a key")
  assert(mutate.set(t1.id, { status = "parked", waits_for = "licence" }, o))
  eq(
    { find(t1.id).status, find(t1.id).waits_for },
    { "parked", "licence" },
    "both at once, as written"
  )

  -- a status change that stays outside `parked` adds nothing to the write
  local t2 = new("Never parked")
  local set3 = assert(mutate.set(t2.id, { status = "doing" }, o))
  eq(set3.before, { status = "open" }, "no waits_for in the inverse of a task that has none")

  -- ── the dashboard's status cycle, the batch ─────────────────────────────
  local cycled =
    batch.set_many(batch.plan_cycle({ find(t1.id) }, "status"), { root = root, today = TODAY })
  eq(#cycled.failed, 0, vim.inspect(cycled.failed))
  eq(find(t1.id).status, "doing", "parked -> doing")
  eq(find(t1.id).waits_for, nil, "the cycle drops the reason with the status")

  -- ── the write door ──────────────────────────────────────────────────────
  local ops = require("tasks_nvim.ops")
  local answer = ops.run({
    client_op_id = "waits-1",
    ops = {
      { op = "set", id = t2.id, patch = { waits_for = "mac" } },
      { op = "new", area = "lib.nvim", title = "Door made", fields = { waits_for = "mac" } },
    },
  }, { root = root, today = TODAY })
  ok(answer.ok, vim.inspect(answer))
  eq({ find(t2.id).status, find(t2.id).waits_for }, { "parked", "mac" })
  eq(
    answer.results[1].inverse.patch.status,
    "doing",
    "the inverse of the door restores the status too"
  )
  eq(find("lib.nvim/door-made").waits_for, "mac")
  eq(find("lib.nvim/door-made").status, "parked")
  local undone = ops.run({
    client_op_id = "waits-2",
    ops = { vim.tbl_extend("force", {}, answer.results[1].inverse) },
  }, { root = root, today = TODAY })
  ok(undone.ok, vim.inspect(undone))
  eq({ find(t2.id).status, find(t2.id).waits_for }, { "doing" }, "undo: back to doing, no reason")
  local refused = ops.run({
    client_op_id = "waits-3",
    ops = { { op = "set", id = t2.id, patch = { waits_for = "My Mac" } } },
  }, { root = root, today = TODAY })
  ok(not refused.ok)
  has(refused.results[1].error.message, "invalid waits_for")

  -- ── done and reopen: a finished or reopened task waits for nothing ──────
  local fin = new("Finish me", { waits_for = "mac" })
  local done = assert(mutate.done(fin.id, o))
  lacks(H.read(done.to), "waits_for", "done drops the reason")
  local back = assert(mutate.reopen(fin.id, o))
  eq(find(fin.id).status, "open")
  lacks(H.read(back.path), "waits_for")
  -- a finished file that still carries one (written by hand): reopening drops it, unless it is reopened as parked
  local stale = new("Stale reason")
  local stale_done = assert(mutate.done(stale.id, o))
  H.write(
    stale_done.to,
    (H.read(stale_done.to):gsub("status: done", "status: done\nwaits_for: mac"))
  )
  assert(mutate.reopen(stale.id, o))
  eq(find(stale.id).waits_for, nil)
  local kept = new("Kept reason")
  local kept_done = assert(mutate.done(kept.id, o))
  H.write(kept_done.to, (H.read(kept_done.to):gsub("status: done", "status: done\nwaits_for: mac")))
  assert(mutate.reopen(kept.id, vim.tbl_extend("force", o, { status = "parked" })))
  eq({ find(kept.id).status, find(kept.id).waits_for }, { "parked", "mac" })

  -- ── the filter ──────────────────────────────────────────────────────────
  local pool = {
    parse(F.meta("m1", "parked", { { "waits_for", "mac" } }), "m1"),
    parse(F.meta("m2", "parked", { { "waits_for", "mac" } }), "m2", "b"),
    parse(F.meta("l1", "parked", { { "waits_for", "licence" } }), "l1"),
    parse(F.meta("p0", "parked"), "p0"),
    parse(F.meta("o1", "open"), "o1"),
    parse(F.meta("o2", "open", { { "waits_for", "mac" } }), "o2"),
  }
  local f = assert(filter_opts.parse({ waits_for = "mac" }))
  eq(f.waits_for, { "mac" })
  eq(
    slugs(model.filter(pool, f)),
    { "m1", "m2" },
    "only parked tasks wait: the open one with a stray key is out"
  )
  f = assert(filter_opts.parse({ waits_for = "licence, none" }))
  eq(slugs(model.filter(pool, f)), { "l1", "p0" }, "`none` is parked without a reason")
  local nf, ferr = filter_opts.parse({ waits_for = "My Mac" })
  eq(nf, nil)
  has(ferr, "invalid key in --waits-for: My Mac")
  local ef, eerr = filter_opts.parse({ waits_for = "" })
  eq(ef, nil)
  has(eerr, "--waits-for needs a value")

  -- ── the overview ────────────────────────────────────────────────────────
  local sum = waits.summary(pool)
  eq({ sum.parked, sum.without, sum.invalid }, { 4, 1, 0 })
  eq(sum.keys, {
    { key = "mac", count = 2, areas = { "a", "b" }, ids = { "a/m1", "b/m2" } },
    { key = "licence", count = 1, areas = { "a" }, ids = { "a/l1" } },
  }, "most tasks first; the open task with a stray key does not count")
  eq(waits.summary({ parse(F.meta("x", "parked", { { "waits_for", "My Mac" } })) }).invalid, 1)
  eq(waits.breakdown(waits.counts(pool)), "2 waiting for mac, 1 for licence")
  eq(waits.breakdown({}), nil)
  eq(waits.parked_text(3, {}), "3 parked", "without a reason the number stands alone, as before")
  eq(waits.parked_text(30, { mac = 25 }), "30 parked (25 waiting for mac)")

  -- ── next: the empty answer says what the parked ones wait for ───────────
  local pick = next_pick.pick({ tasks = { pool[1], pool[2], pool[3], pool[4] } })
  eq(pick.empty.parked, 4)
  eq(pick.empty.waits_for, { mac = 2, licence = 1 })
  eq(
    plan_view.empty_text(pick.empty),
    "Nothing can be started. Still open: 4 parked (2 waiting for mac, 1 for licence)."
  )
  local plain_pick = next_pick.pick({ tasks = { pool[4] } })
  eq(
    plan_view.empty_text(plain_pick.empty),
    "Nothing can be started. Still open: 1 parked.",
    "no reason, no brackets"
  )

  -- ── the plan view ───────────────────────────────────────────────────────
  ---@param tasks Tasks.Task[]
  ---@return string
  local function plan_md(tasks)
    return plan_view.markdown(plan.build(tasks, plan.index(tasks)), { title = "x" })
  end
  local with = plan_md({ pool[1], pool[4], pool[5] })
  has(
    with,
    "3 tasks \194\183 1 ready now \194\183 0 waiting for a decision \194\183 2 parked (1 waiting for mac)"
  )
  has(with, "waits: mac")
  local without = plan_md({ pool[4], pool[5] })
  has(
    without,
    "2 tasks \194\183 1 ready now \194\183 0 waiting for a decision\n",
    "a plan without a reason reads as before"
  )
  lacks(without, "parked (")
  lacks(without, "waits:")

  -- ── the index: byte for byte the same for tasks without the field ───────
  local plain_rows = {
    parse(F.meta("Alpha", "open", { { "prio", "1" }, { "effort", "S" } }), "alpha", "x"),
    parse(F.meta("Beta", "parked", { { "prio", "2" } }), "beta", "x"),
    parse(F.meta("Gamma", "blocked", { { "blocked_by", "[x/alpha]" } }), "gamma", "x"),
    parse(F.meta("Delta", "parked", { { "summary", "Set aside" } }), "delta", "x"),
  }
  local EXPECTED = table.concat({
    "<!-- GENERATED by tasks.nvim (:Tasks index) \226\128\148 do not edit; edit tasks/*.md -->",
    "# x \226\128\148 offene Tasks (4)",
    "",
    "| Status | Prio | Effort | Task | Zusammenfassung |",
    "|---|---|---|---|---|",
    "| blocked | \226\128\147 | \226\128\147 | [Gamma](tasks/gamma.md) | A summary line. (blockiert durch `x/alpha`) |",
    "| open | 1 | S | [Alpha](tasks/alpha.md) | A summary line. |",
    "| parked | 2 | \226\128\147 | [Beta](tasks/beta.md) | A summary line. |",
    "| parked | \226\128\147 | \226\128\147 | [Delta](tasks/delta.md) | Set aside |",
    "",
  }, "\n")
  eq(
    index.render("x", plain_rows),
    EXPECTED,
    "the index of tasks without waits_for is what it always was"
  )
  local reasoned = vim.deepcopy(plain_rows)
  reasoned[2] =
    parse(F.meta("Beta", "parked", { { "prio", "2" }, { "waits_for", "mac" } }), "beta", "x")
  eq(
    index.render("x", reasoned),
    (
      EXPECTED:gsub(
        "%[Beta%]%(tasks/beta%.md%) | A summary line%. |",
        "[Beta](tasks/beta.md) | A summary line. (wartet auf `mac`) |"
      )
    ),
    "only the row of the task that names a reason changes"
  )
  -- a stray key on a task that is not parked, and a value that is no key, leave the row alone
  local stray = vim.deepcopy(plain_rows)
  stray[1] = parse(
    F.meta("Alpha", "open", { { "prio", "1" }, { "effort", "S" }, { "waits_for", "mac" } }),
    "alpha",
    "x"
  )
  eq(index.render("x", stray), EXPECTED)

  -- ── check ───────────────────────────────────────────────────────────────
  local croot = F.vault(H)
  F.task(H, croot, "lib.nvim", "good", F.meta("Good", "parked", { { "waits_for", "mac" } }))
  F.task(H, croot, "lib.nvim", "astray", F.meta("Astray", "open", { { "waits_for", "mac" } }))
  F.task(H, croot, "lib.nvim", "badkey", F.meta("Bad key", "parked", { { "waits_for", "My Mac" } }))
  assert(index.write_area("lib.nvim", { root = croot }))
  local res = assert(check.run({ root = croot }))
  local found = {}
  for _, fnd in ipairs(res.findings) do
    found[#found + 1] = ("%s:%s:%s"):format(fnd.severity, fnd.code, fnd.id or "")
  end
  table.sort(found)
  eq(found, {
    "error:invalid-waits-for:lib.nvim/badkey",
    "warn:waits-for-without-parked:lib.nvim/astray",
  })

  -- ── the dashboard core ──────────────────────────────────────────────────
  local w = dash.widths(pool)
  has(dash.line(pool[1], w), "[waits: mac]")
  lacks(dash.line(pool[4], w), "waits:", "a parked task without a reason carries no mark")
  lacks(dash.line(pool[6], w), "waits:", "nor does a task that is not parked")
  has(dash.search_text(pool[1]), "waits: mac")
  ok(vim.tbl_contains(dash.FILTER_DIMS, "waits_for"))
  eq(dash.dim_choices("waits_for", pool), { "licence", "mac", "none" })
  local df = dash.set_dim({}, "waits_for", "mac")
  eq(df.waits_for, { "mac" })
  eq(dash.chips(df), { "waits for: mac" })
  eq(dash.filter_to_options(df), { waits_for = "mac" })
  eq(
    dash.filter_from_stored(dash.filter_to_options(df)).waits_for,
    { "mac" },
    "the stored filter comes back"
  )
  eq(dash.set_dim(df, "waits_for", nil).waits_for, nil)

  -- a named list carries the filter
  local lists = require("tasks_nvim.lists")
  eq(lists.from_filter(df).waits_for, "mac")
  ok(lists.resolve({ waits_for = "mac,none" }), "a list definition with waits_for parses")

  -- ── the command line ────────────────────────────────────────────────────
  local vroot = F.vault(H)
  ---@param argv string[]
  ---@param today? string
  ---@return { code: integer, out: string, err: string }
  local function run(argv, today)
    local out, err = {}, {}
    local args = vim.deepcopy(argv)
    vim.list_extend(args, { "--vault=" .. vroot, "--today=" .. (today or TODAY) })
    local code = cli.run(args, {
      out = function(text)
        out[#out + 1] = text
      end,
      err = function(text)
        err[#err + 1] = text
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  ---@param text string
  ---@return string[]
  local function lines(text)
    return vim.split((text:gsub("\n$", "")), "\n", { plain = true })
  end
  ---@param id string
  ---@return Tasks.Task
  local function vfind(id)
    return assert(scan.find(id, { root = vroot }))
  end

  eq(run({ "new", "lib.nvim", "Mac one", "--waits-for=mac", "--prio=1" }).code, 0)
  eq(run({ "new", "cascade.nvim", "Mac two", "--waits-for=mac" }).code, 0)
  eq(run({ "new", "lib.nvim", "Licence", "--waits-for=licence" }).code, 0)
  eq(run({ "new", "lib.nvim", "By choice", "--status=parked" }).code, 0)
  eq(run({ "new", "lib.nvim", "Open task", "--value=5", "--effort=XS" }).code, 0)
  eq(vfind("lib.nvim/mac-one").status, "parked")
  local r = run({ "new", "lib.nvim", "Refused", "--waits-for=mac", "--status=doing" })
  eq(r.code, 1)
  has(r.err, "waits_for goes with status parked, not doing")

  r = run({ "set", "lib.nvim/open-task", "waits_for=mac" })
  eq(r.code, 0, r.err)
  eq(
    { vfind("lib.nvim/open-task").status, vfind("lib.nvim/open-task").waits_for },
    { "parked", "mac" }
  )

  r = run({ "list", "--waits-for=mac", "--format=ids" })
  eq(r.code, 0, r.err)
  eq(lines(r.out), { "lib.nvim/mac-one", "cascade.nvim/mac-two", "lib.nvim/open-task" })
  r = run({ "list", "lib.nvim", "--waits-for=none,licence", "--format=ids" })
  eq(lines(r.out), { "lib.nvim/by-choice", "lib.nvim/licence" })
  r = run({ "list", "--waits-for=My Mac" })
  eq(r.code, 2)
  has(r.err, "invalid key in --waits-for")
  -- the reason is a trailing cell; a line of a task without one is what it was
  r = run({ "list", "lib.nvim", "--status=parked" })
  eq(lines(r.out), {
    "lib.nvim/mac-one\tparked\t1\t-\ttask\t" .. TODAY .. "\tMac one\twaits: mac",
    "lib.nvim/by-choice\tparked\t-\t-\ttask\t" .. TODAY .. "\tBy choice",
    "lib.nvim/licence\tparked\t-\t-\ttask\t" .. TODAY .. "\tLicence\twaits: licence",
    "lib.nvim/open-task\tparked\t-\tXS\ttask\t" .. TODAY .. "\tOpen task\twaits: mac",
  })

  -- quickwins hides parked tasks by default; the filter asks for them
  r = run({ "quickwins", "--format=ids" })
  eq(r.out, "", "the parked quick win is not offered by default")
  r = run({ "quickwins", "--waits-for=mac", "--format=ids" })
  eq(lines(r.out), { "lib.nvim/open-task" }, "--waits-for shows the parked tasks the default hides")

  -- waits
  r = run({ "waits" })
  eq(r.code, 0, r.err)
  eq(lines(r.out), {
    "mac\t3\tcascade.nvim,lib.nvim",
    "licence\t1\tlib.nvim",
    "parked without a reason: 1",
    "parked: 5",
  })
  r = run({ "waits", "cascade.nvim" })
  eq(lines(r.out), { "mac\t1\tcascade.nvim", "parked without a reason: 0", "parked: 1" })
  r = run({ "waits", "--format=json" })
  eq(r.code, 0, r.err)
  local doc = vim.json.decode(r.out)
  eq(doc.kind, "tasks.waits")
  eq({ doc.parked, doc.without_reason, doc.invalid }, { 5, 1, 0 })
  eq(doc.keys, {
    { key = "mac", count = 3, areas = { "cascade.nvim", "lib.nvim" } },
    { key = "licence", count = 1, areas = { "lib.nvim" } },
  })
  r = run({ "waits", "nowhere" })
  ok(r.code ~= 0, "an unknown area is refused")

  -- next: nothing can be started, and why
  r = run({ "next" })
  has(r.out, "Still open: 5 parked (3 waiting for mac, 1 for licence).")
  r = run({ "next", "--format=json" })
  eq(
    vim.json.decode(r.out).empty.waits_for,
    { mac = 3, licence = 1 },
    "the document names the keys too"
  )
  r = run({ "show", "lib.nvim/mac-one" })
  has(r.out, "waits_for: mac")
  r = run({ "list", "--waits-for=mac", "--format=json" })
  eq(vim.json.decode(r.out).total, 3)

  -- release
  r = run({ "release" })
  eq(r.code, 2)
  r = run({ "release", "My Mac" })
  eq(r.code, 2)
  has(r.err, "invalid waits_for")
  r = run({ "release", "windows" })
  eq(r.code, 1)
  has(r.err, "no parked task waits for 'windows'")
  r = run({ "release", "mac", "--dry-run" })
  eq(r.code, 0, r.err)
  eq(lines(r.out), {
    "would-release\tcascade.nvim/mac-two",
    "would-release\tlib.nvim/mac-one",
    "would-release\tlib.nvim/open-task",
    "release\tmac\tdry-run\t3 task(s); nothing written",
  })
  eq(vfind("lib.nvim/mac-one").status, "parked", "a dry run writes nothing")

  r = run({ "release", "mac" }, "2026-10-09")
  eq(r.code, 0, r.err)
  eq(lines(r.out), {
    "released\tcascade.nvim/mac-two",
    "released\tlib.nvim/mac-one",
    "released\tlib.nvim/open-task",
    "release\tmac\t3 released, 0 failed",
  })
  for _, id in ipairs({ "cascade.nvim/mac-two", "lib.nvim/mac-one", "lib.nvim/open-task" }) do
    local t = vfind(id)
    eq({ t.status, t.waits_for, t.updated }, { "open", nil, "2026-10-09" }, id)
    lacks(H.read(t.path), "waits_for")
  end
  eq(vfind("lib.nvim/licence").waits_for, "licence", "another key is not touched")
  eq(vfind("lib.nvim/by-choice").status, "parked", "nor a task parked by choice")
  -- the indexes of both areas were written again: no reason of the released key is left in them
  lacks(H.read(vroot .. "/lib.nvim/ROADMAP/TASKS.md"), "wartet auf `mac`")
  has(H.read(vroot .. "/lib.nvim/ROADMAP/TASKS.md"), "wartet auf `licence`")
  has(H.read(vroot .. "/cascade.nvim/ROADMAP/TASKS.md"), "| open |")
  eq(run({ "index", "--check" }).code, 0, "the indexes are current after a release")
  r = run({ "waits" })
  eq(lines(r.out), { "licence\t1\tlib.nvim", "parked without a reason: 1", "parked: 2" })

  -- ── `:Tasks waits`, `:Tasks release`, `:Tasks set`, `:Tasks list --waits-for` ──
  local composer = require("lib.nvim.bindings.usercmd.composer")
  local routes = require("tasks_nvim.ui.routes")

  local confirm = require("tasks_nvim.ui.confirm")
  local vault = require("tasks_nvim.vault")
  local eroot = F.vault(H)
  local eo = { root = eroot, today = TODAY }
  assert(
    mutate.new("lib.nvim", vim.tbl_extend("force", eo, { title = "Ed one", waits_for = "mac" }))
  )
  assert(
    mutate.new("cascade.nvim", vim.tbl_extend("force", eo, { title = "Ed two", waits_for = "mac" }))
  )
  assert(mutate.new("lib.nvim", vim.tbl_extend("force", eo, { title = "Ed open" })))
  vault.set_root(eroot)
  routes.register_types()
  composer.verb("TaskW", { routes = routes.routes({ flat = true }) })
  local orig_notify, orig_yesno = vim.notify, confirm.yesno
  ---@type string[]
  local notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  ---@type string[]
  local asked = {}
  local answer_yes = false
  confirm.yesno = function(msg, _, cb)
    asked[#asked + 1] = msg
    cb(answer_yes)
  end
  ---@param line string
  ---@return string
  local function ex(line)
    notes = {}
    vim.cmd("TaskW " .. line)
    vim.wait(30, function()
      return false
    end)
    return table.concat(notes, "\n")
  end
  ---@param id string
  ---@return Tasks.Task
  local function efind(id)
    return assert(scan.find(id, { root = eroot }))
  end
  local good, failure = pcall(function()
    local said = ex("waits")
    has(said, "mac: 2  (cascade.nvim, lib.nvim)")
    has(said, "parked without a reason: 0")
    has(said, "parked: 2")

    ex("set lib.nvim/ed-open waits_for=mac")
    eq(
      { efind("lib.nvim/ed-open").status, efind("lib.nvim/ed-open").waits_for },
      { "parked", "mac" }
    )

    said = ex("release mac --dry-run")
    has(said, "release mac would set 3 task(s) to open")
    eq(efind("lib.nvim/ed-one").status, "parked")
    eq(#asked, 0, "a dry run asks nothing")

    answer_yes = false
    ex("release mac")
    eq(#asked, 1, "the release asks first")
    has(asked[1], "3 parked task(s) that wait for 'mac'")
    eq(efind("lib.nvim/ed-one").status, "parked", "No leaves everything as it was")

    answer_yes = true
    said = ex("release mac")
    has(said, "release mac: 3 task(s) set to open")
    for _, id in ipairs({ "lib.nvim/ed-one", "cascade.nvim/ed-two", "lib.nvim/ed-open" }) do
      eq({ efind(id).status, efind(id).waits_for }, { "open" }, id)
    end

    said = ex("release mac --yes")
    has(said, "no parked task waits for 'mac'")
    said = ex("release My_Mac")
    has(said, "invalid waits_for")

    -- a task created parked with a reason from the command line
    ex("new lib.nvim Ed made waits_for=budget")
    eq(
      { efind("lib.nvim/ed-made").status, efind("lib.nvim/ed-made").waits_for },
      { "parked", "budget" }
    )
    asked = {}
    ex("release budget --yes")
    eq(#asked, 0, "--yes skips the question")
    eq(efind("lib.nvim/ed-made").status, "open")
  end)
  vim.notify = orig_notify
  confirm.yesno = orig_yesno
  vault.set_root(nil)
  pcall(vim.cmd, "silent! %bwipeout!")
  if not good then
    error(failure, 0)
  end
end
