-- TESTS/tasks_path_marks_spec.lua -- the marks `{machine=…}` and `{safety}` of a learning point: the parser (own and
-- inherited marks, bad values, the unmarked "Sicherheit"), the write-back of a changed line, the filter and the
-- safety lines of `tasks path`, `ack` on `node_set`, and the contract (capability `path_marks`, the node fields).
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local lernbaum = require("tasks_nvim.lernbaum")
  local stats = require("tasks_nvim.path_stats")
  local ops_mod = require("tasks_nvim.ops")
  local api = require("tasks_nvim.api")

  local BODY = table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lesen {#lesen}",
    "- [ ] Dienste starten {machine=wsl} {#dienste}",
    "- [ ] Netz üben {machine=private,workstation} {#netz}",
    "- [ ] Strom {safety} {#strom}",
    "  - [ ] Netzteil öffnen {#netzteil}",
    "  - [ ] Messen {machine=workstation} {xp=5} {#messen}",
    "- [ ] Gruppe {machine=wsl} {#gruppe}",
    "  - [ ] Kind erbt {#erbt}",
    "  - [ ] Kind eigen {machine=private} {#eigen}",
    "",
  }, "\n")
  local tree = lernbaum.parse(BODY)
  eq(#tree.problems, 0, vim.inspect(tree.problems))
  local by = tree.by_key

  -- ── parser ──
  eq(by.lesen.machine, nil)
  eq(by.lesen.machine_eff, nil, "no mark: every machine")
  eq(by.dienste.machine, { "wsl" })
  eq(by.netz.machine, { "private", "workstation" })
  eq(by.dienste.label, "Dienste starten", "the marks leave the label")
  eq(by.strom.safety, true)
  eq(by.netzteil.safety, nil)
  eq(by.netzteil.safety_eff, by.strom, "a child is under its parent's {safety}")
  eq(by.messen.machine_eff, { "workstation" })
  eq(by.erbt.machine_eff, { "wsl" }, "a child takes its parent's machines")
  eq(by.eigen.machine_eff, { "private" }, "a child's own mark wins")
  eq(by.messen.xp_own, 5, "the other marks still parse beside them")
  ok(lernbaum.on_machine(by.lesen, "workstation"), "unmarked: everywhere")
  ok(lernbaum.on_machine(by.dienste, "private"), "the private machine has WSL")
  ok(not lernbaum.on_machine(by.dienste, "workstation"), "the workstation has none")
  ok(
    not lernbaum.on_machine(by.netz, "wsl"),
    "wsl stays strict: a private-only point is not for it"
  )
  ok(lernbaum.on_machine(by.netz, "workstation"), "listed")
  eq(lernbaum.machine_of_role(""), "private")
  eq(lernbaum.machine_of_role("Default"), "private")
  eq(lernbaum.machine_of_role("WORKSTATION"), "workstation")
  eq(lernbaum.machine_of_role("laptop"), nil)

  -- ── a changed line keeps the marks ──
  local t2 = lernbaum.parse(BODY)
  assert(lernbaum.set_state(t2, "dienste", "learned"))
  local rendered = lernbaum.render(t2)
  has(rendered, "- [x] Dienste starten {machine=wsl} {#dienste}")
  assert(lernbaum.set_state(t2, "netzteil", "learned"))
  assert(lernbaum.set_xp(t2, "messen", 7))
  has(lernbaum.render(t2), "{xp=7} {machine=workstation} {#messen}")

  local t3 = lernbaum.parse(
    table.concat({ "## Lernpunkte", "- [ ] Löten {safety} {machine=private} {#loeten}", "" }, "\n")
  )
  assert(lernbaum.set_state(t3, "loeten", "learned"))
  has(
    lernbaum.render(t3),
    "- [x] Löten {machine=private} {safety} {#loeten}",
    "{safety} survives a changed line"
  )

  -- ── faults ──
  local bad = lernbaum.parse(table.concat({
    "## Lernpunkte",
    "- [ ] A {machine=mars} {#a}",
    "- [ ] B {machine=} {#b}",
    "- [ ] Sicherheit: Steckdose {#s1}",
    "- [ ] Sicherheit: Steckdose {safety} {#s2}",
    "- [ ] Block {safety} {#blk}",
    "  - [ ] Sicherheit beachten {#s3}",
    "",
  }, "\n"))
  local codes = {}
  for _, p in ipairs(bad.problems) do
    codes[#codes + 1] = p.code .. ":" .. tostring(p.key)
  end
  table.sort(codes)
  eq(codes, { "path-bad-machine:a", "path-bad-machine:b", "path-safety-unmarked:s1" })

  -- ── stats.marks ──
  local m = stats.marks(tree, nil)
  eq(#m.safety, 1)
  eq(m.safety[1].key, "strom")
  eq(m.hidden, 0)
  m = stats.marks(tree, "workstation")
  local todo = {}
  for _, t in ipairs(m.todo) do
    todo[#todo + 1] = t.key
  end
  eq(todo, { "lesen", "netz", "netzteil", "messen" })
  eq(m.hidden, 3, "dienste, erbt, eigen are for other machines")
  eq(m.todo[3].under.label, "Strom", "a point under {safety} names the parent")
  eq(m.todo[3].safety, true)
  m = stats.marks(tree, "private")
  eq(m.hidden, 1, "only messen (workstation): the wsl points go on the private machine")
  -- progress is untouched by the filter
  eq(stats.compute(tree, nil).points.open, 7)

  -- ── tasks path ──
  local root = F.vault(H)
  local A = "lib.nvim"
  local ID = A .. "/maschinen"
  H.write(
    root .. "/" .. A .. "/ROADMAP/paths/maschinen.md",
    "---\ntitle: Maschinen\nstatus: doing\n---\n" .. BODY
  )
  local function run(argv)
    local out, err = {}, {}
    vim.list_extend(argv, { "--vault=" .. root, "--today=" .. F.TODAY })
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
  local code, out, err = run({ "path", ID })
  eq(code, 0, err)
  has(out, "safety\t#strom\tStrom\t(line 7)")
  ok(
    out:find("safety\t", 1, true) < out:find("points\t", 1, true),
    "safety comes before the counts"
  )
  ok(not out:find("todo\t", 1, true), "no filter without --machine")
  code, out, err = run({ "path", ID, "--machine=workstation" })
  eq(code, 0, err)
  has(out, "machine\tworkstation\thidden 3\topen here 4")
  has(out, "todo\t#netzteil\tNetzteil öffnen\t(line 8)\tsafety\tunder: Strom")
  ok(not out:find("#dienste", 1, true), "a wsl-only point is hidden on the workstation")
  has(out, "points\t7\topen 7", "progress counts every point, shown or not")
  code, out = run({ "path", ID, "--machine=wsl", "--format=json" })
  eq(code, 0)
  local doc = vim.json.decode(out)
  eq(doc.machine.role, "wsl")
  eq(doc.machine.hidden, 3)
  eq(doc.safety[1].key, "strom")
  code, out = run({ "path", ID, "--machine=private", "--format=json" })
  eq(code, 0)
  doc = vim.json.decode(out)
  eq(doc.machine.hidden, 1, "only the workstation point is hidden on the private machine")
  local shown = {}
  for _, t in ipairs(doc.machine.todo) do
    shown[#shown + 1] = t.key
  end
  ok(vim.tbl_contains(shown, "dienste"), "a wsl point is shown on the private machine")
  local _
  code, _, err = run({ "path", ID, "--machine=mars" })
  eq(code, 2)
  has(err, "--machine takes")
  code = run({ "path", ID, "--schedule", "--machine=wsl" })
  eq(code, 2, "no filter for the schedule")

  -- ── ack on node_set ──
  local function node_set(point, state, ack)
    local doc2 = assert(ops_mod.run({
      ops = { { op = "node_set", id = ID, point = point, state = state, ack = ack } },
    }, { root = root, today = F.TODAY }))
    return doc2.results[1]
  end
  local r = node_set("netzteil", "learned")
  eq(r.ok, false, "a point under {safety} needs ack")
  eq(r.error.code, "invalid_argument")
  has(r.error.message, "{safety}")
  r = node_set("strom", "learned")
  eq(r.ok, false, "the marked point itself too")
  r = node_set("netzteil", "learned", true)
  eq(r.ok, true, vim.inspect(r))
  has(H.read(root .. "/" .. A .. "/ROADMAP/paths/maschinen.md"), "- [x] Netzteil öffnen")
  r = node_set("lesen", "learned")
  eq(r.ok, true, "a point outside {safety} needs no ack")
  r = node_set("netzteil", "open")
  eq(r.ok, true, "reopening needs no ack")

  -- ── the contract ──
  local function call(method, params)
    local text = api.call(method, { params = params or {} }, { root = root, today = F.TODAY })
    return vim.json.decode(text)
  end
  local hello = call("hello")
  eq(type(hello), "table", "hello")
  ok(vim.tbl_contains(hello.capabilities, "path_marks"), "capability path_marks")
  local pd = call("path", { id = ID })
  local nodes = {}
  for _, n in ipairs(pd.nodes) do
    nodes[n.key] = n
  end
  eq(nodes.dienste.machine, { "wsl" })
  eq(nodes.erbt.machine, { "wsl" })
  eq(nodes.netzteil.safety, true)
  eq(nodes.strom.safety, true)
  eq(nodes.lesen.machine, nil)
  eq(nodes.lesen.safety, nil)
end
