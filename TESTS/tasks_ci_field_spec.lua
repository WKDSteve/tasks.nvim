-- TESTS/tasks_ci_field_spec.lua -- `ci`: the CI state of a task's commits (pending, green, red) beside `commits`.
-- The field (model, `check`), the writes (`done --ci`, `set ci=` on an open task and on a finished one in Backlog/,
-- through the CLI and the write door), the listing (`list --done --ci=`, `show`), the contract entries and the next
-- round of a routine. A task without `ci` reads and finishes as before.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local contract = require("tasks_nvim.contract")
  local filter_opts = require("tasks_nvim.filter_opts")
  local fsio = require("tasks_nvim.fsio")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local ops = require("tasks_nvim.ops")
  local scan = require("tasks_nvim.scan")

  local TODAY = F.TODAY or "2026-11-19"

  -- ── the words ─────────────────────────────────────────────────────────────
  eq(model.CI_STATES, { "pending", "green", "red" })
  for _, w in ipairs(model.CI_STATES) do
    ok(model.is_ci(w), w .. " is a ci state")
  end
  for _, w in ipairs({ "Green", "passed", "", "none" }) do
    ok(not model.is_ci(w), "'" .. w .. "' is no ci state")
  end
  ok(not model.is_ci(nil))

  -- ── model ─────────────────────────────────────────────────────────────────
  ---@param meta table[]
  ---@return Tasks.Task
  local function parse(meta)
    return model.parse_text(F.text(meta), {
      path = "/v/a/ROADMAP/tasks/t.md",
      area = "a",
      location = "roadmap",
    })
  end
  local green = parse(F.meta("G", "open", { { "ci", "green" } }))
  ok(green.valid, vim.inspect(green.errors))
  eq(green.ci, "green")
  eq(parse(F.meta("P", "open")).ci, nil, "no ci: not known")
  local wrong = parse(F.meta("W", "open", { { "ci", "yellow" } }))
  ok(not wrong.valid, "an unknown word is an error")
  eq(wrong.error_codes, { "unknown-ci" })
  has(wrong.errors[1], "unknown ci 'yellow' (expected pending, green, red)")

  -- ── done --ci and set ci= ─────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local function new(title)
    return assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title })))
  end
  local function run(argv)
    local out, err = {}, {}
    local args = vim.deepcopy(argv)
    vim.list_extend(args, { "--vault=" .. root, "--today=" .. TODAY })
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local function done_text(id)
    return H.read(assert(scan.find_done(id, { root = root })).path)
  end

  -- the regression first: a finish without --ci writes none
  local plain = new("Plain finish")
  local r = run({ "done", plain.id, "--commits=lib.nvim@abc1234" })
  eq(r.code, 0, r.err)
  lacks(done_text(plain.id), "ci:", "no --ci, no key")

  local pend = new("Pushed and waiting")
  r = run({ "done", pend.id, "--commits=lib.nvim@abc1234", "--ci=pending" })
  eq(r.code, 0, r.err)
  has(
    done_text(pend.id),
    "commits: [lib.nvim@abc1234]\nci: pending\n",
    "written beside the commits"
  )

  local refused = new("Wrong word")
  r = run({ "done", refused.id, "--ci=yellow" })
  eq(r.code, 1)
  has(r.err, "unknown ci 'yellow'")
  ok(scan.find(refused.id, { root = root }), "a refused finish leaves the task open")
  local _, _, info = mutate.done(refused.id, vim.tbl_extend("force", o, { ci = "passed" }))
  eq(info and info.code, "invalid_argument", "the caller's mistake, not internal")

  -- an open task keeps its own ci through a finish that names none
  local own = new("Own state")
  assert(mutate.set(own.id, { ci = "red" }, o))
  eq(assert(scan.find(own.id, { root = root })).ci, "red", "set ci= on an open task")
  has(select(2, mutate.set(own.id, { ci = "yellow" }, o)), "ci")
  assert(mutate.done(own.id, o))
  has(done_text(own.id), "ci: red\n", "the task's own ci stays")

  -- the verdict later: set ci= on the finished task in Backlog/, its `updated` stays
  local before = done_text(pend.id)
  local updated_before = before:match("\nupdated: ([%d-]+)\n")
  r = run({ "set", pend.id, "ci=green", "--today=2026-12-01" })
  eq(r.code, 0, r.err)
  local after = done_text(pend.id)
  has(after, "ci: green\n", "set reaches the finished task")
  eq(after:match("\nupdated: ([%d-]+)\n"), updated_before, "bookkeeping does not move updated")
  eq(after:gsub("ci: green", "ci: pending"), before, "nothing else of the finished file changes")
  r = run({ "set", pend.id, "ci=red", "title=Renamed" })
  eq(r.code, 1, "ci together with another key is no bookkeeping: the finished task is not found")
  has(done_text(pend.id), "ci: green\n")
  r = run({ "set", pend.id, "ci=" })
  eq(r.code, 0, r.err)
  lacks(done_text(pend.id), "ci:", "an empty value takes it away")
  assert(mutate.set(pend.id, { ci = "red" }, o))
  has(done_text(pend.id), "ci: red\n")
  eq(mutate.BOOKKEEPING, { remind = true, remind_at = true, remind_to = true, ci = true })

  -- ── list --done --ci= and show ────────────────────────────────────────────
  local all = run({ "list", "lib.nvim", "--done" })
  eq(all.code, 0, all.err)
  has(all.out, "lib.nvim/pushed-and-waiting\tdone ci=red\t", "the state rides on the status")
  has(all.out, "lib.nvim/plain-finish\tdone\t", "a task without ci lists as it always did")
  local ids = function(res)
    local list = vim.split(vim.trim(res.out), "\n")
    table.sort(list)
    return list
  end
  eq(
    ids(run({ "list", "lib.nvim", "--done", "--ci=pending,red", "--format=ids" })),
    { "lib.nvim/own-state", "lib.nvim/pushed-and-waiting" }
  )
  eq(vim.trim(run({ "list", "lib.nvim", "--done", "--ci=green", "--format=ids" }).out), "")
  local none = ids(run({ "list", "lib.nvim", "--done", "--ci=none", "--format=ids" }))
  ok(vim.tbl_contains(none, "lib.nvim/plain-finish"), "none: no ci written")
  ok(not vim.tbl_contains(none, "lib.nvim/own-state"))
  eq(select(2, filter_opts.parse({ ci = "passed" })), "unknown ci state in --ci: passed")
  eq(select(2, filter_opts.parse({ ci = "," })), "--ci needs a value (pending, green, red, none)")
  r = run({ "list", "lib.nvim", "--done", "--ci=passed" })
  eq(r.code, 2)
  has(r.err, "unknown ci state in --ci: passed")

  -- ── the contract ─────────────────────────────────────────────────────────
  ok(vim.tbl_contains(contract.CAPABILITIES, "ci"), "capability ci")
  local fin =
    assert(contract.finished({ area = "lib.nvim", limit = 100 }, { root = root, today = TODAY }))
  local by_id = {}
  for _, item in ipairs(fin.items) do
    by_id[item.id] = item
  end
  eq(by_id["lib.nvim/pushed-and-waiting"].ci, "red", "tasks.finished carries ci")
  eq(by_id["lib.nvim/plain-finish"].ci, nil, "only when the file has it")

  -- `finished` narrowed by the CI state (capability `finished_ci`): what an overview counts as "CI open or red"
  ok(vim.tbl_contains(contract.CAPABILITIES, "finished_ci"), "capability finished_ci")
  local function ids_of(params)
    local doc, err = contract.finished(
      vim.tbl_extend("force", { limit = 100 }, params),
      { root = root, today = TODAY }
    )
    assert(doc, vim.inspect(err))
    local list = vim.tbl_map(function(item)
      return item.id
    end, doc.items)
    table.sort(list)
    return list, doc.total
  end
  local open_or_red, total = ids_of({ ci = { "pending", "red" } })
  eq(open_or_red, { "lib.nvim/own-state", "lib.nvim/pushed-and-waiting" }, "pending or red")
  eq(total, 2, "total counts the matching ones: the number an overview shows")
  local none_ids = ids_of({ ci = { "none" } })
  ok(vim.tbl_contains(none_ids, "lib.nvim/plain-finish"), "none: no ci written")
  ok(not vim.tbl_contains(none_ids, "lib.nvim/own-state"))
  eq(#ids_of({}), #fin.items, "without ci every finished task, as before")
  for _, bad in ipairs({ { "yellow" }, {}, "pending", { "pending", 1 } }) do
    local doc, err = contract.finished({ ci = bad }, { root = root, today = TODAY })
    eq(doc, nil, "refused: " .. vim.inspect(bad))
    eq(err and err.code, "invalid_argument")
  end
  -- through the request door: a list of words
  local reply_text = require("tasks_nvim.api").call(
    "finished",
    vim.json.encode({ params = { ci = { "red" }, area = "lib.nvim" } }),
    { root = root, today = TODAY }
  )
  local reply = vim.json.decode(reply_text)
  eq(reply.kind, "tasks.finished", vim.inspect(reply))
  eq(reply.total, 2, "own-state and pushed-and-waiting are red")

  local tdoc =
    assert(contract.task("lib.nvim/own-state", { root = root, today = TODAY, finished = true }))
  eq(tdoc.task.ci, "red", "the task entry carries ci")

  -- the write door: done takes ci, set takes it on a finished task
  local function one(op)
    local doc, err = ops.run({ ops = { op } }, { root = root, today = TODAY })
    eq(doc and doc.kind, "tasks.result", vim.inspect(err))
    return doc.results[1]
  end
  local door = new("Through the door")
  local e = one({ op = "done", id = door.id, ci = "yellow", confirm = "x" })
  eq(e.ok, false)
  eq(e.error.code, "invalid_argument")
  has(e.error.message, "unknown ci 'yellow'")
  local etag = fsio.etag(H.read(door.path))
  e = one({
    op = "done",
    id = door.id,
    ci = "pending",
    confirm = mutate.confirm_token(door.id, etag),
  })
  eq(e.ok, true, vim.inspect(e))
  has(done_text(door.id), "ci: pending\n")
  e = one({ op = "set", id = door.id, patch = { ci = "green" } })
  eq(e.ok, true, vim.inspect(e))
  has(done_text(door.id), "ci: green\n", "the write door sets ci on the finished task")
  e = one({ op = "set", id = door.id, patch = { ci = "red", prio = 1 } })
  eq(e.ok, false, "not with another key")
  has(done_text(door.id), "ci: green\n")
  e = one({ op = "set", id = door.id, patch = { remind = "2026-12-24" } })
  eq(e.ok, true, "remind alone still goes: " .. vim.inspect(e))

  -- ── a routine's next round starts without it ─────────────────────────────
  local routine = new("Weekly")
  assert(mutate.set(routine.id, { ["repeat"] = "1w", due = TODAY, ci = "red" }, o))
  local flow = assert(require("tasks_nvim.done_flow").run(routine.id, {
    root = root,
    today = TODAY,
    index = false,
    pick_next = false,
    ci = "pending",
  }))
  has(done_text(routine.id), "ci: pending\n", "the finished round keeps its state")
  local round = assert(scan.find(flow.next_round.id, { root = root }))
  eq(round.ci, nil, "the next round has no ci of its own")

  -- ── the editor: `:Tasks done <id> ci=pending --yes` hands it to the finish ──
  local ui_cmd = require("tasks_nvim.ui.cmd")
  local vault = require("tasks_nvim.vault")
  local editor = new("By the editor")
  local prev_root = vault.root()
  vault.set_root(root)
  local real_notify = vim.notify
  vim.notify = function() end
  local called, cerr = pcall(ui_cmd.task_done, {
    rest = {},
    args = { id = editor.id },
    kv = { ci = "pending" },
    flags = { yes = true },
  })
  vim.notify = real_notify
  if prev_root then
    vault.set_root(prev_root)
  end
  ok(called, tostring(cerr))
  has(done_text(editor.id), "ci: pending\n", ":Tasks done passes ci=")
end
