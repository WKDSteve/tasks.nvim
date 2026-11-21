-- TESTS/tasks_requires_spec.lua -- learning paths and projects that build on each other (`requires`,
-- `requires_gate`, `tasks_nvim.requires`): reading the fields, `path-new` / `set` with known ids and no circle, the
-- soft gate (a note) and the hard one (not finished before the requirement, the line of the whole path stays open),
-- the project level (one project needs another), `check`, the documents (capability `requires`) and the shell views.
-- @scans-data: the spec lists only its own fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local check = require("tasks_nvim.check")
  local cli = require("tasks_nvim.cli")
  local done_flow = require("tasks_nvim.done_flow")
  local ops_mod = require("tasks_nvim.ops")
  local paths = require("tasks_nvim.paths")
  local plans = require("tasks_nvim.plans")
  local req = require("tasks_nvim.requires")

  local root = F.vault(H)
  local TODAY = F.TODAY
  local o = { root = root, today = TODAY }
  local A = "lib.nvim"

  ---@param argv string[]
  ---@return integer code
  ---@return string out
  ---@return string err
  local function run_cli(argv)
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
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end
  local function op(list, dry)
    local doc, err = ops_mod.run({ ops = list, dry_run = dry or nil }, o)
    assert(doc, vim.inspect(err))
    return doc.results[1]
  end
  local function call(method, params)
    local text = api.call(method, { params = params or {} }, o)
    return vim.json.decode(text)
  end
  ---@return table<string, string[]>
  local function codes_of(result)
    local out = {}
    for _, f in ipairs(result.findings) do
      out[f.code] = out[f.code] or {}
      table.insert(out[f.code], f.id or f.path)
    end
    return out
  end
  ---The generated overview of a project (what `projects --of=<id> --write=<file>` writes).
  local function overview(id)
    local plan_scope = require("tasks_nvim.plan_scope")
    return assert(plan_scope.overview_body(id, root, assert(plan_scope.shared(root)))).body or ""
  end
  local function new_path(title, extra)
    local made, err = paths.new(A, vim.tbl_extend("force", o, { title = title }, extra or {}))
    assert(made, err)
    return made
  end

  ok(vim.tbl_contains(call("hello").capabilities, "requires"), "capability requires")

  -- ── path-new: known ids only, written as a list; the gate soft or hard ──
  local hobby = new_path("Elektronik Hobby")
  local _, uerr, uinfo = paths.new(
    A,
    vim.tbl_extend("force", o, { title = "Digital", requires = "lib.nvim/gibt-es-nicht" })
  )
  ok(uerr and uerr:find("no learning path or project", 1, true), tostring(uerr))
  eq(uinfo.problems[1].code, "requires-unknown")
  local _, gerr = paths.new(
    A,
    vim.tbl_extend("force", o, { title = "Digital", requires = hobby.id, requires_gate = "weich" })
  )
  ok(gerr and gerr:find("soft or hard", 1, true), tostring(gerr))
  local _, perr = plans.new(A, vim.tbl_extend("force", o, { title = "Plan", requires = hobby.id }))
  ok(perr and perr:find("a plan has no requires", 1, true), "a plan has no requires")
  local digital = new_path("Digitaltechnik", { requires = { hobby.id }, requires_gate = "hard" })
  local text = H.read(digital.path)
  has(text, "requires: [" .. hobby.id .. "]", "the list in the frontmatter")
  has(text, "requires_gate: hard")
  local d = assert(paths.find(digital.id, o))
  ok(d.valid, table.concat(d.errors, "; "))
  eq(d.requires, { hobby.id })
  eq(d.requires_gate, "hard")

  -- a hand-written fault of the file: a bad gate, an entry twice
  local bad = new_path("Kaputt")
  H.write(
    bad.path,
    (
      H.read(bad.path):gsub(
        "\ntitle:",
        "\nrequires: [" .. hobby.id .. ", " .. hobby.id .. "]\nrequires_gate: sanft\ntitle:",
        1
      )
    )
  )
  local b = assert(paths.find(bad.id, o))
  ok(vim.tbl_contains(b.error_codes, "path-bad-requires"), vim.inspect(b.error_codes))
  ok(vim.tbl_contains(b.error_codes, "path-bad-requires-gate"), vim.inspect(b.error_codes))
  H.write(bad.path, (H.read(bad.path):gsub("requires: %b[]\nrequires_gate: sanft\n", "", 1)))

  -- ── state: waiting, held ──
  local idx = req.index({ root = root })
  local st = req.state(d, idx)
  eq(st.waiting_on, { hobby.id })
  eq(st.held, true)
  eq(
    st.requirements[1],
    { id = hobby.id, kind = "path", gate = "hard", met = false, title = "Elektronik Hobby" }
  )
  eq(req.state(assert(paths.find(hobby.id, o)), idx), nil, "nothing required: no state")

  -- ── set: a circle is refused, an unknown id too, the shell list form is read ──
  local cyc, cerr, cinfo = plans.set(
    hobby.id,
    { requires = { digital.id } },
    { root = root, kind = "path" }
  )
  eq(cyc, nil)
  ok(cerr and cerr:find("circle", 1, true), tostring(cerr))
  eq(cinfo.problems[1].code, "requires-cycle")
  local _, serr = plans.set(hobby.id, { requires = { hobby.id } }, { root = root, kind = "path" })
  ok(serr and serr:find("circle", 1, true), "naming itself is a circle: " .. tostring(serr))
  local _, nerr = plans.set(
    hobby.id,
    { requires = "lib.nvim/nirgends" },
    { root = root, kind = "path" }
  )
  ok(nerr and nerr:find("no learning path or project", 1, true), tostring(nerr))
  local basics = new_path("Grundlagen")
  local code, out, err = run_cli({ "set", hobby.id, "requires=[" .. basics.id .. "]" })
  eq(code, 0, err)
  has(out, "changed")
  eq(assert(paths.find(hobby.id, o)).requires, { basics.id })
  code, _, err = run_cli({ "set", hobby.id, "requires=" })
  eq(code, 0, err)
  eq(assert(paths.find(hobby.id, o)).requires, {}, "an empty value removes the list")
  ok(not H.read(hobby.path):find("requires:", 1, true), "the key is gone")

  -- ── tasks-ops/1: path_set with requires, its inverse; path_new refused for an unknown id ──
  local set = op({ { op = "path_set", id = basics.id, patch = { requires = { hobby.id } } } })
  eq(set.outcome, "changed", vim.inspect(set))
  eq(set.inverse.patch.requires, vim.NIL, "the key the file did not have")
  local refused = op({ { op = "path_set", id = hobby.id, patch = { requires = { basics.id } } } })
  eq(refused.ok, false)
  eq(refused.error.code, "invalid_argument")
  eq(refused.error.details.problems[1].code, "requires-cycle", vim.inspect(refused))
  local unknown = op({
    { op = "path_new", area = A, title = "Neu", requires = { "lib.nvim/nirgends" } },
  }, true)
  eq(unknown.ok, false)
  eq(unknown.error.details.problems[1].code, "requires-unknown", vim.inspect(unknown))
  eq(op({ { op = "path_set", id = basics.id, patch = { requires = vim.NIL } } }).outcome, "changed")

  -- ── the hard gate: the line of the whole path stays open, the path cannot be finished ──
  local head = H.read(digital.path):match("^(%-%-%-\n.-\n%-%-%-\n)")
  H.write(digital.path, head .. table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [x] Gatter {#gatter}",
    "",
    "## Level",
    "",
    "- [ ] 50 %",
    "- [ ] Pfad fertig · Belohnung: Lötstation",
    "",
  }, "\n"))
  local pdoc = call("path", { id = digital.id })
  eq(pdoc.path.waiting_on, { { id = hobby.id } })
  eq(pdoc.path.requires_gate, "hard")
  eq(pdoc.path.requires, { { id = hobby.id, gate = "hard", kind = "path", met = false } })
  eq(pdoc.path.stage, "waiting")
  eq(pdoc.path.level.finished, false, "held: the path is not finished")
  eq(#pdoc.path.level.open_rewards, 0, "the reward of the whole path is not reached")
  for _, l in ipairs(pdoc.levels) do
    if l.ref == "done" then
      eq(l.reached, false, "the line of the whole path stays open")
    else
      eq(l.reached, true, "the other levels are reached")
    end
  end
  -- the tree view of the editor: the reward of the whole path is not open while the path waits
  local learn = require("tasks_nvim.ui.learn")
  require("tasks_nvim.vault").set_root(root)
  vim.cmd("silent edit! " .. vim.fn.fnameescape(digital.path))
  local lbuf = vim.api.nvim_get_current_buf()
  learn.attach(lbuf)
  local function heading_text()
    local texts = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(lbuf, learn.ns, 0, -1, { details = true })) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        texts[#texts + 1] = chunk[1]
      end
    end
    return table.concat(texts, "\n")
  end
  ok(
    not heading_text():find("Belohnung offen", 1, true),
    "held: no open reward in the view: " .. heading_text()
  )
  local listed = call("paths", { area = A })
  local rev_before = listed.rev
  for _, item in ipairs(listed.items) do
    if item.id == digital.id then
      eq(item.waiting_on, { { id = hobby.id } })
    elseif item.id == hobby.id then
      eq(item.requires, nil, "a path without requires reads as before")
      eq(item.waiting_on, nil)
      eq(item.stage, "idle")
    end
  end
  code, out = run_cli({ "path", digital.id })
  eq(code, 0)
  has(out, "requires\t" .. hobby.id .. "\topen\thard")
  has(out, "gate\thard\twaits for " .. hobby.id)
  code, out = run_cli({ "paths", A })
  eq(code, 0)
  has(out, "\twaits for " .. hobby.id)

  local _, herr, hinfo = paths.close(digital.id, o)
  ok(herr and herr:find("waits for " .. hobby.id, 1, true), tostring(herr))
  eq(hinfo.waiting_on, { hobby.id })
  local refused_close = op({ { op = "path_close", id = digital.id } }, true)
  eq(refused_close.ok, false, "refused in a dry run too")
  eq(refused_close.error.details.waiting_on, { { id = hobby.id } })

  -- the requirement finished: the gate opens, the revision moves, the line is reached
  assert(paths.close(hobby.id, o))
  local after = call("paths", { area = A })
  ok(after.rev ~= rev_before, "a finished requirement gives a new revision")
  pdoc = call("path", { id = digital.id })
  eq(pdoc.path.waiting_on, {})
  eq(pdoc.path.requires[1].met, true)
  eq(pdoc.path.stage, "doing", "a point learned")
  eq(pdoc.path.level.finished, true)
  learn.forget_task_xp(lbuf)
  learn.refresh(lbuf)
  has(heading_text(), "Belohnung offen: Lötstation", "the gate is open: the reward is reached")
  vim.cmd("silent! bwipeout! " .. lbuf)
  require("tasks_nvim.vault").set_root(nil)
  local closed = assert(paths.close(digital.id, o))
  eq(closed.notes or {}, {}, "nothing to say")

  -- ── the soft gate: a hint, never a wait; finished anyway, with a note ──
  local first = new_path("Erst")
  local soft = new_path("Danach", { requires = first.id })
  eq(assert(paths.find(soft.id, o)).requires_gate, nil, "soft is the default")
  for _, item in ipairs(call("paths", { area = A }).items) do
    if item.id == soft.id then
      eq(item.waiting_on, {}, "an open soft requirement is no wait")
      eq(item.requires, { { id = first.id, gate = "soft", kind = "path", met = false } })
      eq(item.stage, "idle", "it keeps its stage")
    end
  end
  code, out = run_cli({ "path", soft.id })
  eq(code, 0)
  has(out, "gate\tsoft\tbuilds on " .. first.id .. " (not finished)")
  local soft_closed = op({ { op = "path_close", id = soft.id } })
  eq(soft_closed.outcome, "closed", vim.inspect(soft_closed))
  has(soft_closed.notes[1], "finished before " .. first.id)

  -- ── include_done: the finished paths too, the circles, the finished projects a requirement names ──
  local all = call("paths", { area = A, include_done = true })
  local by_id = {}
  for _, item in ipairs(all.items) do
    by_id[item.id] = item
  end
  eq(by_id[hobby.id].stage, "done")
  eq(by_id[hobby.id].status, "done")
  eq(by_id[soft.id].requires, { { id = first.id, gate = "soft", kind = "path", met = false } })
  eq(by_id[soft.id].waiting_on, {}, "a finished path waits for nothing")
  eq(all.requires_cycles, {})
  eq(all.done_projects, {})
  eq(call("paths", { area = A }).requires_cycles, nil, "no open file names a requirement: no field")
  ok(not vim.tbl_contains(
    vim.tbl_map(function(i)
      return i.id
    end, call("paths", { area = A }).items),
    hobby.id
  ), "without include_done: open ones only")

  -- ── projects: one needs another ──
  local pa =
    assert(plans.new(A, vim.tbl_extend("force", o, { kind = "project", title = "Hobby-Niveau" })))
  local pb = assert(plans.new(
    A,
    vim.tbl_extend("force", o, {
      kind = "project",
      title = "Digital-Projekt",
      requires = pa.id,
      requires_gate = "hard",
    })
  ))
  local snap = call("snapshot")
  local entry
  for _, p in ipairs(snap.projects) do
    if p.id == pb.id then
      entry = p
    elseif p.id == pa.id then
      eq(p.requires, nil, "a project without requires reads as before")
    end
  end
  eq(entry.waiting_on, { { id = pa.id } })
  eq(entry.requires, { { id = pa.id, gate = "hard", kind = "project", met = false } })
  local res = done_flow.close_projects({ pb.id }, o)
  eq(res.closed, {})
  eq(res.waiting[pb.id], { pa.id })
  local pref = op({ { op = "project_close", id = pb.id } })
  eq(pref.ok, false)
  eq(pref.error.details.waiting_on, { { id = pa.id } }, vim.inspect(pref))
  code, out = run_cli({ "projects", A })
  eq(code, 0)
  has(out, "waits for " .. pa.id)
  out = overview(pb.id)
  has(out, "Builds on: waits for " .. pa.id)
  -- a path of the project inherits its hard requirement (`via` the project), its own soft one is a hint
  local pending = new_path("Vorher")
  local in_project = new_path("Im Projekt", { project = pb.id, requires = pending.id })
  out = overview(pb.id)
  has(out, "planning, waits for " .. pa.id .. " (via " .. pb.id .. ")")
  for _, item in ipairs(call("paths", { area = A }).items) do
    if item.id == in_project.id then
      eq(item.waiting_on, { { id = pa.id, via = pb.id } })
      eq(item.stage, "waiting")
    end
  end
  local _, ierr, iinfo = paths.close(in_project.id, o)
  ok(ierr and ierr:find("via " .. pb.id, 1, true), tostring(ierr))
  eq(iinfo.waiting, { { id = pa.id, via = pb.id } })

  assert(done_flow.close_projects({ pa.id }, o).closed[1] == pa.id)
  -- the finished project an open one names: a box at the end of the arrow
  local done_all = call("paths", { area = A, include_done = true })
  eq(done_all.done_projects, { { id = pa.id, area = A, title = "Hobby-Niveau" } })
  out = overview(pb.id)
  has(out, "planning, builds on " .. pending.id .. " (not finished)")
  local in_closed = assert(paths.close(in_project.id, o))
  has(in_closed.notes[1], "finished before " .. pending.id)
  local ok_close = done_flow.close_projects({ pb.id }, o)
  eq(ok_close.closed, { pb.id }, vim.inspect(ok_close))

  -- ── check: an unknown id and a circle written by hand ──
  local x = new_path("X-Pfad")
  local y = new_path("Y-Pfad", { requires = x.id })
  H.write(
    x.path,
    (H.read(x.path):gsub("\ntitle:", "\nrequires: [" .. y.id .. ", lib.nvim/weg]\ntitle:", 1))
  )
  local found = codes_of(assert(check.run({ root = root, area = A })))
  eq(found["requires-unknown"], { x.id })
  eq(#(found["requires-cycle"] or {}), 1, vim.inspect(found["requires-cycle"]))
  eq(call("paths", { area = A }).requires_cycles, { { x.id, y.id } }, "the same circle")

  -- a circle through a project's hard requirement, which its paths inherit: a path of the project that a requirement
  -- of the project needs could never be finished
  local proj =
    assert(plans.new(A, vim.tbl_extend("force", o, { kind = "project", title = "Kreis-Projekt" })))
  local inner = new_path("Innen", { project = proj.id })
  local outer = new_path("Aussen", { requires = inner.id })
  local _, kerr, kinfo = plans.set(
    proj.id,
    { requires = { outer.id }, requires_gate = "hard" },
    { root = root, kind = "project" }
  )
  ok(kerr and kerr:find("circle", 1, true), "refused: " .. tostring(kerr))
  eq(kinfo and kinfo.problems[1].code, "requires-cycle")
  -- the same written by hand: check names it
  H.write(
    proj.path,
    (
      H.read(proj.path)
        :gsub("\ntitle:", "\nrequires: [" .. outer.id .. "]\nrequires_gate: hard\ntitle:", 1)
    )
  )
  found = codes_of(assert(check.run({ root = root, area = A })))
  eq(#(found["requires-cycle"] or {}), 2, vim.inspect(found["requires-cycle"]))
  -- a project that needs one of its own paths is no circle: the path inherits nothing from it about itself
  local own = new_path("Eigen", { project = proj.id })
  H.write(proj.path, (H.read(proj.path):gsub("requires: %b[]", "requires: [" .. own.id .. "]", 1)))
  found = codes_of(assert(check.run({ root = root, area = A })))
  eq(#(found["requires-cycle"] or {}), 1, vim.inspect(found["requires-cycle"]))
  -- a plan file with the field is a fault of the plan
  local plan = assert(plans.new(A, vim.tbl_extend("force", o, { title = "Ein Plan" })))
  H.write(
    plan.path,
    (H.read(plan.path):gsub("\ntitle:", "\nrequires: [" .. x.id .. "]\ntitle:", 1))
  )
  found = codes_of(assert(check.run({ root = root, area = A })))
  eq(found["plan-requires"], { plan.id })
end
