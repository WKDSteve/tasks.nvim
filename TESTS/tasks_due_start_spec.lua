-- TESTS/tasks_due_start_spec.lua -- the optional dates `due` (deadline) and `start` (earliest day to begin).
-- Model (format, start after due), `set`, `new`, the contract entry. Not the reminder: see tasks_remind_spec.lua.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local api = require("tasks_nvim.api")

  -- ── the model ──────────────────────────────────────────────────────────
  local function parse(front)
    return model.parse_text(
      "---\ntitle: A\nstatus: open\n" .. front .. "created: 2026-01-01\n---\n\nBody.\n",
      { path = "/v/a/ROADMAP/tasks/a.md", area = "a" }
    )
  end
  local good = parse("start: 2026-02-01\ndue: 2026-03-01\n")
  eq(good.start, "2026-02-01")
  eq(good.due, "2026-03-01")
  eq(good.valid, true)
  ok(parse("due: 2026-03-01\nstart: 2026-03-01\n").valid, "the same day is allowed")
  ok(parse("").due == nil, "optional")

  local late = parse("start: 2026-04-01\ndue: 2026-03-01\n")
  ok(vim.tbl_contains(late.error_codes, "start-after-due"), table.concat(late.error_codes, ","))
  eq(late.valid, false)
  local bad = parse("due: soon\n")
  ok(vim.tbl_contains(bad.error_codes, "bad-date"), table.concat(bad.error_codes, ","))
  eq(bad.valid, false)

  -- ── set ────────────────────────────────────────────────────────────────
  local root = fixture.build(H)
  local file = root .. "/lib.nvim/ROADMAP/tasks/alpha.md"
  local opts = { root = root, today = "2026-03-01", index = false }
  local r, serr = mutate.set("lib.nvim/alpha", { due = "2026-05-01", start = "2026-04-01" }, opts)
  ok(r, tostring(serr))
  has(H.read(file), "due: 2026-05-01")
  has(H.read(file), "start: 2026-04-01")

  local _, e1 = mutate.set("lib.nvim/alpha", { due = "2026-03-15" }, opts)
  has(e1, "after due", "a due date before the file's start is refused")
  local _, e2 = mutate.set("lib.nvim/alpha", { start = "2026-06-01" }, opts)
  has(e2, "after due", "a start after the file's due date is refused")
  local _, e3 = mutate.set("lib.nvim/alpha", { due = "next week" }, opts)
  has(e3, "due")
  has(e3, "YYYY-MM-DD")
  has(H.read(file), "due: 2026-05-01", "a refused patch changes nothing")

  local moved = mutate.set("lib.nvim/alpha", { start = "2026-04-20", due = "2026-04-25" }, opts)
  ok(moved, "both change together, judged on the result")
  ok(mutate.set("lib.nvim/alpha", { start = mutate.REMOVE }, opts))
  ok(not H.read(file):find("start:", 1, true), "taken away")
  has(H.read(file), "due: 2026-04-25")
  ok(mutate.set("lib.nvim/alpha", { due = mutate.REMOVE }, opts))
  ok(not H.read(file):find("due:", 1, true), "taken away")

  -- a file that starts after it is due (written by hand) stays editable by a patch that leaves the dates alone
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/handmade.md",
    table.concat({
      "---",
      "title: Handmade",
      "status: open",
      "start: 2026-05-01",
      "due: 2026-04-01",
      "created: 2026-01-01",
      "updated: 2026-01-01",
      "---",
      "",
      "Body.",
      "",
    }, "\n")
  )
  ok(
    mutate.set("lib.nvim/handmade", { prio = 2 }, opts),
    "an unrelated patch is not refused for the dates"
  )
  local _, still = mutate.set("lib.nvim/handmade", { start = "2026-05-02" }, opts)
  has(still, "after due", "a patch that touches a date is judged on the result")
  ok(
    mutate.set("lib.nvim/handmade", { due = "2026-06-01" }, opts),
    "and the date that fixes it is accepted"
  )

  -- ── new ────────────────────────────────────────────────────────────────
  local n, nerr = mutate.new("lib.nvim", {
    title = "With dates",
    due = "2026-09-01",
    start = "2026-08-01",
    root = root,
    today = "2026-03-01",
    index = false,
  })
  ok(n, tostring(nerr))
  local text = H.read(n.path)
  has(text, "due: 2026-09-01")
  has(text, "start: 2026-08-01")
  local _, ne = mutate.new("lib.nvim", {
    title = "Backwards",
    due = "2026-08-01",
    start = "2026-09-01",
    root = root,
    index = false,
  })
  has(ne, "after due")
  local _, nd =
    mutate.new("lib.nvim", { title = "Odd", due = "tomorrow", root = root, index = false })
  has(nd, "YYYY-MM-DD")

  -- ── the dates survive done, reopen and a move to another area ────────
  local dated = mutate.new(
    "lib.nvim",
    { title = "Keeps dates", due = "2026-09-09", start = "2026-09-01", root = root, index = false }
  )
  local moves = require("tasks_nvim.moves")
  local mv, merr = moves.move(dated.id, "cascade.nvim", { root = root, index = false })
  ok(mv, tostring(merr))
  local moved_text = H.read(mv.to)
  has(moved_text, "due: 2026-09-09")
  has(moved_text, "start: 2026-09-01")
  local finished, ferr = require("tasks_nvim.done_flow").run(
    mv.new_id,
    { root = root, today = "2026-03-01", index = false, pick_next = false }
  )
  ok(finished, tostring(ferr))
  local done_text = H.read(finished.done.to)
  has(done_text, "due: 2026-09-09")
  has(done_text, "start: 2026-09-01")
  local back, berr = mutate.reopen(mv.new_id, { root = root, today = "2026-03-01", index = false })
  ok(back, tostring(berr))
  local reopened = H.read(back.path)
  has(reopened, "due: 2026-09-09")
  has(reopened, "start: 2026-09-01")

  -- ── filters and the sort order ────────────────────────────────────────
  local filter_opts = require("tasks_nvim.filter_opts")
  local function task(slug, front)
    local t = model.parse_text(
      "---\ntitle: " .. slug .. "\nstatus: open\n" .. front .. "created: 2026-01-01\n---\n\nBody.\n",
      { path = "/v/a/ROADMAP/tasks/" .. slug .. ".md", area = "a", slug = slug }
    )
    t.id = "a/" .. slug
    return t
  end
  local sample = {
    task("none", ""),
    task("late", "due: 2026-03-20\n"),
    task("early", "due: 2026-02-10\nstart: 2026-02-01\n"),
    task("later", "due: 2026-06-01\nstart: 2026-05-01\n"),
  }
  ---@param opt table
  ---@return string[]
  local function ids_of(opt)
    opt.today = "2026-03-01"
    local f = assert(filter_opts.parse(opt))
    local ids = vim.tbl_map(function(t)
      return t.id
    end, model.sort(model.filter(vim.list_slice(sample, 1), f), "due"))
    return ids
  end
  eq(ids_of({}), { "a/early", "a/late", "a/later", "a/none" }, "earliest due first, undated last")
  eq(ids_of({ overdue = true }), { "a/early" }, "before today; the undated never match")
  eq(ids_of({ due_before = "2026-04-01" }), { "a/early", "a/late" })
  eq(ids_of({ due_before = "2026-02-10" }), {}, "before, not on the day")
  eq(ids_of({ starts_after = "2026-03-01" }), { "a/later" })
  local _, derr = filter_opts.parse({ due_before = "soon" })
  has(derr, "--due-before")
  local _, starts_err = filter_opts.parse({ starts_after = "2026-13-40" })
  has(starts_err, "--starts-after")
  eq(model.parse_sort("due"), "due", "a sort word the lists accept")

  -- ── the contract ───────────────────────────────────────────────────────
  local function call(method, params)
    local raw = api.call(method, params and vim.json.encode({ params = params }) or nil, {
      root = root,
      today = "2026-03-01",
    })
    return vim.json.decode(raw)
  end
  local doc = call("task", { id = n.id })
  eq(doc.task.due, "2026-09-01")
  eq(doc.task.start, "2026-08-01")
  local plain = call("task", { id = "lib.nvim/beta" })
  ok(plain.task.due == nil and plain.task.start == nil, "a task without the fields reads as before")

  -- the order method names its sort word in the document, and the schema lists `due` for it
  local ordered = call("order", { sort = "due" })
  eq(ordered.sort, "due")
  eq(ordered.ids[1], "cascade.nvim/iota", "the earliest due date (2026-03-01) first")
  local function at(id)
    return vim.fn.index(ordered.ids, id)
  end
  ok(at(n.id) >= 0 and at("lib.nvim/beta") >= 0, "both are in the order")
  ok(at(n.id) < at("lib.nvim/beta"), "a task with a due date comes before an undated one")
  local schema =
    vim.json.decode(H.read(here .. "/../schemas/tasks-export/1/tasks-export.schema.json"))
  local enum
  for _, def in pairs(schema["$defs"]) do
    local props = type(def) == "table" and def.properties or nil
    if props and props.kind and props.kind.const == "tasks.order" then
      enum = props.sort and props.sort.enum
    end
  end
  ok(enum ~= nil, "the definition of tasks.order is found in the schema")
  ok(vim.tbl_contains(enum or {}, "due"), "and its sort enum has due")

  -- ── the ops door: new with fields, set with a patch ───────────────────
  local function ops(list)
    local raw =
      api.call("ops", vim.json.encode({ ops = list }), { root = root, today = "2026-03-01" })
    return vim.json.decode(raw)
  end
  local res = ops({
    { op = "new", area = "lib.nvim", title = "Via ops", fields = { due = "2026-10-10" } },
  })
  ok(res.results and res.results[1].ok, vim.json.encode(res))
  local refused = ops({ { op = "set", id = "lib.nvim/beta", patch = { start = "x" } } })
  local entry = refused.results and refused.results[1] or refused
  ok(entry.ok == false, "a bad date is refused through the door too: " .. vim.json.encode(refused))
  ok(
    not H.read(root .. "/lib.nvim/ROADMAP/tasks/beta.md"):find("start: x", 1, true),
    "and not written"
  )
end
