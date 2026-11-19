-- TESTS/tasks_contract_outcome_spec.lua -- `outcome` in the contract (capability `outcome`): the fields of a task entry
-- (`outcome`, `outcome_reason`, `point`), `done_preview` with an outcome, the `done` operation with its required reason
-- and the learning point it writes back, `groupings`; a task without the fields reads as before.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local ops_mod = require("tasks_nvim.ops")
  local promote = require("tasks_nvim.promote")

  local root = F.vault(H)
  local TODAY = F.TODAY
  local function call(method, params)
    local text = api.call(method, { params = params or {} }, { root = root, today = TODAY })
    local doc = vim.json.decode(text)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end
  local function run(list, dry)
    local doc, err = ops_mod.run(
      { ops = list, dry_run = dry or nil },
      { root = root, today = TODAY }
    )
    assert(doc, tostring(err))
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    return doc.results[1]
  end
  local function token(id)
    local t = assert(mutate.find_open(id, root))
    return mutate.confirm_token(id, fsio.etag(assert(fsio.read(t.path))))
  end

  F.task(H, root, "lib.nvim", "plain", F.meta("Plain", "open"))
  F.task(
    H,
    root,
    "lib.nvim",
    "noted",
    F.meta("Noted", "open", { { "outcome", "seen" }, { "outcome_reason", "no Mac" } })
  )

  -- the handshake names the capability
  local hello = call("hello")
  ok(vim.tbl_contains(hello.capabilities, "outcome"))

  -- an entry without the fields reads as before; a note in advance is carried
  local plain = call("task", { id = "lib.nvim/plain" })
  eq(plain.task.outcome, nil)
  eq(plain.task.outcome_reason, nil)
  eq(plain.task.point, nil)
  local noted = call("task", { id = "lib.nvim/noted" })
  eq(noted.task.outcome, "seen")
  eq(noted.task.outcome_reason, "no Mac")

  -- groupings: outcome is a field one can set
  local g = call("groupings")
  local field
  for _, f in ipairs(g.fields) do
    if f.field == "outcome" then
      field = f
    end
  end
  eq(field and field.values, { "learned", "seen", "not-applicable" })
  eq(field and field.mode, "set")

  -- done_preview with an outcome: the row names it; without a reason seen is refused
  local pv = call("done_preview", { id = "lib.nvim/plain", outcome = "learned" })
  eq(pv.kind, "tasks.donepreview", vim.inspect(pv))
  eq(pv.outcome, "learned")
  has(pv.readme.row, ", learned) |")
  local _, code = call("done_preview", { id = "lib.nvim/plain", outcome = "seen" })
  eq(code, "invalid_argument")
  local before = call("done_preview", { id = "lib.nvim/plain" })
  eq(before.outcome, nil, "a preview without an outcome reads as before")

  -- the done operation: a bad word and a missing reason are refused before anything is written
  local bad = run({
    { op = "done", id = "lib.nvim/plain", confirm = token("lib.nvim/plain"), outcome = "maybe" },
  })
  eq(bad.ok, false)
  has(bad.error.message, "unknown outcome 'maybe'")
  local need = run({
    { op = "done", id = "lib.nvim/plain", confirm = token("lib.nvim/plain"), outcome = "seen" },
  })
  eq(need.ok, false)
  has(need.error.message, "needs a reason")

  -- a promoted task: done writes the learning point back and names it
  H.write(
    root .. "/lib.nvim/ROADMAP/paths/lua.md",
    "---\ntitle: Lua\nstatus: doing\nupdated: "
      .. TODAY
      .. "\n---\n\n## Lernpunkte\n\n- [ ] C lernen {#c}\n"
  )
  local pr = assert(promote.promote("lib.nvim/lua", "c", { root = root, today = TODAY }))
  local listed = call("task", { id = pr.id })
  eq(listed.task.point, "lib.nvim/lua#c", "the entry names where the task came from")
  local res = run({
    {
      op = "done",
      id = pr.id,
      confirm = token(pr.id),
      outcome = "not-applicable",
      outcome_reason = "C kommt später",
    },
  })
  eq(res.ok, true, vim.inspect(res))
  eq(res.point, { container = "lib.nvim/lua", key = "c", state = "dropped", changed = true })
  ok(vim.tbl_contains(res.changed_ids, "lib.nvim/lua"), "the path is a changed file too")
  has(H.read(root .. "/lib.nvim/ROADMAP/paths/lua.md"), "- [-] C lernen")

  -- the finished entry carries it
  local fin = call("finished", { area = "lib.nvim" })
  local item
  for _, i in ipairs(fin.items) do
    if i.id == pr.id then
      item = i
    end
  end
  eq(item and item.outcome, "not-applicable")
  eq(item and item.outcome_reason, "C kommt später")
  eq(item and item.point, "lib.nvim/lua#c")

  -- reopen and set to blocked take the point along: the path is a changed file of each
  local lua_path = root .. "/lib.nvim/ROADMAP/paths/lua.md"
  local re = run({ { op = "reopen", id = pr.id } })
  eq(re.ok, true, vim.inspect(re))
  ok(vim.tbl_contains(re.changed_ids, "lib.nvim/lua"), "reopen: " .. vim.inspect(re.changed_ids))
  has(H.read(lua_path), "- [ ] C lernen")
  local bl = run({ { op = "set", id = pr.id, patch = { status = "blocked" } } })
  eq(bl.ok, true, vim.inspect(bl))
  ok(vim.tbl_contains(bl.changed_ids, "lib.nvim/lua"), "set: " .. vim.inspect(bl.changed_ids))
  has(H.read(lua_path), "- [!] C lernen")
  local same = run({ { op = "set", id = pr.id, patch = { prio = 2 } } })
  eq(same.changed_ids, { pr.id }, "a set that keeps the status names the task alone")
end
