-- TESTS/tasks_path_ops_spec.lua -- the learning paths through the write door `tasks-ops/1`: `path_new` (dry run,
-- template), `path_set` (with its inverse), `node_set` (a point's state, its inverse, a refused reason, `if_match`),
-- `promote` and `unpromote` (the inverse of the one is the other), `path_close`.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local ops_mod = require("tasks_nvim.ops")
  local scan = require("tasks_nvim.scan")

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

  local hello = call("hello")
  for _, cap in ipairs({ "path_new", "path_set", "path_close", "node_set", "promote" }) do
    ok(vim.tbl_contains(hello.capabilities, cap), cap)
  end

  -- ── path_new ──────────────────────────────────────────────────────────────
  local dry = run({ { op = "path_new", area = "lib.nvim", title = "Lua lernen" } }, true)
  eq(dry.ok, true, vim.inspect(dry))
  eq(dry.outcome, "would_create")
  eq(dry.id, "lib.nvim/lua-lernen")
  eq(call("paths").items, {}, "a dry run makes nothing")
  local made = run({
    { op = "path_new", area = "lib.nvim", title = "Lua lernen", template = "learning" },
  })
  eq(made.outcome, "created")
  local file = root .. "/lib.nvim/ROADMAP/paths/lua-lernen.md"
  has(H.read(file), "## Quellen\n", "the learning template")
  -- a path has no stages: `phases` is no field of `path_new`, so the whole request is refused
  local stages, serr = ops_mod.run(
    { ops = { { op = "path_new", area = "lib.nvim", title = "X", phases = { "a" } } } },
    { root = root, today = TODAY }
  )
  eq(stages, nil)
  eq(serr and serr.code, "invalid_argument", vim.inspect(serr))

  -- ── path_set ──────────────────────────────────────────────────────────────
  local set = run({ { op = "path_set", id = "lib.nvim/lua-lernen", patch = { status = "doing" } } })
  eq(set.outcome, "changed", vim.inspect(set))
  eq(set.inverse.op, "path_set")
  has(H.read(file), "status: doing\n")

  -- the tree, written as a person would
  H.write(
    file,
    (
      H.read(file):gsub(
        "<!%-%- %- %[ %] Punkt.-%-%->",
        "- [ ] Syntax {#syntax}\n- [ ] C lernen {#c}\n  - [ ] K&R"
      )
    )
  )
  local tree = call("path", { id = "lib.nvim/lua-lernen" })
  eq(#tree.nodes, 3, vim.inspect(tree.nodes))

  -- ── node_set ──────────────────────────────────────────────────────────────
  local need =
    run({ { op = "node_set", id = "lib.nvim/lua-lernen", point = "syntax", state = "seen" } })
  eq(need.ok, false)
  eq(need.error.code, "invalid_argument")
  has(need.error.message, "needs a reason")
  local learned = run({
    { op = "node_set", id = "lib.nvim/lua-lernen", point = "#1", state = "learned" },
  })
  eq(learned.outcome, "changed", vim.inspect(learned))
  eq(learned.node.state, "learned")
  eq(learned.progress.learned, 1)
  eq(learned.inverse, {
    op = "node_set",
    id = "lib.nvim/lua-lernen",
    point = "syntax",
    state = "open",
    if_match = learned.etag_after,
  })
  local stale = run({
    {
      op = "node_set",
      id = "lib.nvim/lua-lernen",
      point = "syntax",
      state = "open",
      if_match = learned.etag_before,
    },
  })
  eq(stale.ok, false)
  eq(stale.error.code, "conflict", "a change on an old version is refused")
  local back = run({ learned.inverse })
  eq(back.outcome, "changed", "the inverse puts the point back")
  has(H.read(file), "- [ ] Syntax {#syntax}")

  -- node_set with a note: written below the point; the inverse carries the note it had ("" for none)
  ok(vim.tbl_contains(hello.capabilities, "node_note"), "node_note")
  local nothing_given = run({ { op = "node_set", id = "lib.nvim/lua-lernen", point = "syntax" } })
  eq(nothing_given.ok, false)
  eq(nothing_given.error.code, "invalid_argument")
  local cr = run({
    { op = "node_set", id = "lib.nvim/lua-lernen", point = "syntax", note = "a\rb" },
  })
  eq(cr.ok, false, "a carriage return is a control character")
  local noted = run({
    {
      op = "node_set",
      id = "lib.nvim/lua-lernen",
      point = "syntax",
      note = "Zeile eins\nZeile zwei",
    },
  })
  eq(noted.outcome, "changed", vim.inspect(noted))
  eq(noted.node.state, "open")
  has(H.read(file), "- [ ] Syntax {#syntax}\n  > Zeile eins\n  > Zeile zwei\n- [ ] C lernen {#c}")
  eq(noted.inverse, {
    op = "node_set",
    id = "lib.nvim/lua-lernen",
    point = "syntax",
    note = "",
    if_match = noted.etag_after,
  })
  eq(call("path", { id = "lib.nvim/lua-lernen" }).nodes[1].note, "Zeile eins\nZeile zwei")
  -- state and note in one op: the inverse gives back both
  local both = run({
    {
      op = "node_set",
      id = "lib.nvim/lua-lernen",
      point = "syntax",
      state = "learned",
      note = "neu",
    },
  })
  eq(both.inverse.state, "open")
  eq(both.inverse.note, "Zeile eins\nZeile zwei")
  eq(run({ both.inverse }).outcome, "changed")
  eq(run({ noted.inverse }).outcome, "changed")
  has(
    H.read(file),
    "- [ ] Syntax {#syntax}\n- [ ] C lernen {#c}",
    "the inverses take the note away"
  )

  -- ── promote / unpromote ───────────────────────────────────────────────────
  local pdry = run({ { op = "promote", container = "lib.nvim/lua-lernen", point = "c" } }, true)
  eq(pdry.outcome, "would_create", vim.inspect(pdry))
  eq(pdry.id, "lib.nvim/c-lernen")
  eq(scan.find("lib.nvim/c-lernen", { root = root }), nil)
  local pr = run({ { op = "promote", container = "lib.nvim/lua-lernen", point = "c" } })
  eq(pr.outcome, "created", vim.inspect(pr))
  eq(pr.promoted_from, "lib.nvim/lua-lernen#c")
  eq(pr.moved, 1)
  ok(vim.tbl_contains(pr.changed_ids, "lib.nvim/lua-lernen"))
  ok(vim.tbl_contains(pr.changed_ids, "lib.nvim/c-lernen"))
  eq(
    pr.inverse,
    { op = "unpromote", id = "lib.nvim/c-lernen", container = "lib.nvim/lua-lernen", point = "c" }
  )
  ok(scan.find("lib.nvim/c-lernen", { root = root }), "the task is there")
  local un = run({ pr.inverse })
  eq(un.outcome, "removed", vim.inspect(un))
  eq(scan.find("lib.nvim/c-lernen", { root = root }), nil, "the inverse takes it back")
  has(H.read(file), "- [ ] C lernen {#c}\n  - [ ] K&R")
  local nothing = run({ { op = "promote", container = "lib.nvim/nope", point = "c" } })
  eq(nothing.error.code, "not_found")

  -- plan_new takes the template too: the stages of a learning plan
  local lp =
    run({ { op = "plan_new", area = "lib.nvim", title = "Lernplan", template = "learning" } })
  eq(lp.outcome, "created", vim.inspect(lp))
  has(
    H.read(root .. "/lib.nvim/ROADMAP/plans/lernplan.md"),
    "phase_order: [orientieren, grundlagen, vertiefen, anwenden, festigen]"
  )

  -- ── path_close ────────────────────────────────────────────────────────────
  local cdry = run({ { op = "path_close", id = "lib.nvim/lua-lernen" } }, true)
  eq(cdry.outcome, "would_close")
  local closed = run({ { op = "path_close", id = "lib.nvim/lua-lernen" } })
  eq(closed.outcome, "closed", vim.inspect(closed))
  eq(call("paths").items, {}, "the path left the open ones")
  eq(run({ { op = "path_close", id = "lib.nvim/lua-lernen" } }).outcome, "unchanged")
end
