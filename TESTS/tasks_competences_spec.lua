-- TESTS/tasks_competences_spec.lua -- the competences of a vault (`tasks_nvim.competences`, capability `competences`):
-- stages and targets as written (halves, `?`, a map read from its line), a broken file, the fields `competence` and
-- `competence_target` of a path (read, written by `path_set` with its inverse, refused when wrong), the findings of
-- `check`, the document `tasks.competences` and `tasks competences`. The document itself is the golden `competences`.
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
  local comp = require("tasks_nvim.competences")

  -- ── stages and targets ────────────────────────────────────────────────────
  eq({ comp.level_of("3") }, { 3 })
  eq({ comp.level_of("3.5") }, { 3.5 })
  eq({ comp.level_of("3,5") }, { 3.5 })
  eq({ comp.level_of(8) }, { 8 })
  eq({ comp.level_of("?") }, {}, "? is not assessed: no stage, no fault")
  eq(select(2, comp.level_of("9")), true)
  eq(select(2, comp.level_of("3.3")), true, "halves only")
  eq(select(2, comp.level_of("-1")), true)
  eq(select(2, comp.level_of("drei")), true)
  eq(comp.target_of("4"), { t = 4, p = 4 }, "one stage holds for both")
  eq(comp.target_of("{t: 4, p: 4.5}"), { t = 4, p = 4.5 })
  eq(comp.target_of("{p: 2}"), { p = 2 })
  eq(comp.target_of("{t: 9}"), nil)
  eq(comp.target_of("{t: 1, t: 2}"), nil)
  eq(comp.target_of("{x: 1}"), nil)
  eq(comp.target_of("{}"), nil)
  eq(comp.render_target({ t = 4, p = 3.5 }), "{t: 4, p: 3.5}")

  local c = comp.parse(
    "---\ntitle: OS\nt: 3.5\np: ?\ntarget_12: {t: 4, p: 4}\nassessed: 2026-10-29\n---\nWarum.\n",
    { path = "/v/a/ROADMAP/competences/os.md", area = "a" }
  )
  eq(c.valid, true, vim.inspect(c.errors))
  eq(c.id, "a/os")
  eq(c.t, 3.5)
  eq(c.p, nil)
  eq(c.target_12, { t = 4, p = 4 })
  eq(c.body, "Warum.\n")
  local broken = comp.parse(
    "---\ntitle: X\nt: 10\ntarget_24: viel\nassessed: gestern\nfoo: 1\n---\n",
    { path = "/v/a/ROADMAP/competences/x.md", area = "a" }
  )
  eq(broken.valid, false)
  table.sort(broken.error_codes)
  eq(
    broken.error_codes,
    { "bad-date", "competence-bad-level", "competence-bad-target", "competence-unknown-field" }
  )
  eq(comp.parse("---\nt: 1\n---\n", { path = "/v/a/x/y.md", area = "a" }).error_codes, {
    "title-missing",
  })

  -- ── the vault ─────────────────────────────────────────────────────────────
  local root = F.vault(H)
  G.write_learn_paths(root)
  local function call(method, params)
    local doc = vim.json.decode((api.call(method, { params = params or {} }, { root = root })))
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end
  ok(vim.tbl_contains(call("hello").capabilities, "competences"))
  local doc = call("competences")
  eq(doc.kind, "tasks.competences")
  eq(#doc.items, 2)
  eq(doc.items[1].paths, { "lib.nvim/prozesse" })
  eq(#doc.scale, 9)
  eq(doc.scale[4], { level = 3, name = "Profi" })
  eq(#call("competences", { area = "cascade.nvim" }).items, 0)
  eq(select(2, call("competences", { area = "nope" })), "not_found")
  -- English names in an English vault
  local marker = require("tasks_nvim.vault_marker")
  H.write(root .. "/tasks-vault.json", marker.render({ lang = "en" }))
  local en = call("competences")
  eq(en.lang, "en")
  eq(en.scale[4].name, "Professional")
  ok(en.rev ~= doc.rev, "the language is part of the rev")
  H.write(root .. "/tasks-vault.json", marker.render({}))

  -- the path entry
  local paths = call("paths")
  local proz
  for _, it in ipairs(paths.items) do
    if it.id == "lib.nvim/prozesse" then
      proz = it
    end
  end
  eq(proz.competence, { "lib.nvim/betriebssysteme" })
  eq(proz.competence_target, { t = 4, p = 3.5 }, "the map read from its line")

  -- path_set: both fields, the inverse, the refusals
  local function ops(list)
    local d =
      vim.json.decode((api.call("ops", { client_op_id = "c", ops = list }, { root = root })))
    return d
  end
  local r = ops({
    {
      op = "path_set",
      id = "lib.nvim/signale",
      patch = { competence = { "lib.nvim/netze" }, competence_target = { t = 2 } },
    },
  })
  eq(r.results[1].ok, true, vim.inspect(r))
  local sig = H.read(root .. "/lib.nvim/ROADMAP/paths/signale.md")
  has(sig, "competence: [lib.nvim/netze]")
  has(sig, 'competence_target: "{t: 2}"')
  eq(call("competences").items[2].paths, { "lib.nvim/signale" })
  local back = ops({ r.results[1].inverse })
  eq(back.results[1].ok, true, vim.inspect(back))
  sig = H.read(root .. "/lib.nvim/ROADMAP/paths/signale.md")
  ok(not sig:find("competence"), "the inverse removes both again")
  -- the map on its line is replaced, and the inverse brings it back as it was
  r = ops({
    { op = "path_set", id = "lib.nvim/prozesse", patch = { competence_target = "5" } },
  })
  eq(r.results[1].ok, true, vim.inspect(r))
  eq(r.results[1].inverse.patch.competence_target, "{t: 4, p: 3.5}")
  has(H.read(root .. "/lib.nvim/ROADMAP/paths/prozesse.md"), 'competence_target: "{t: 5, p: 5}"')
  ops({ r.results[1].inverse })
  eq(call("path", { id = "lib.nvim/prozesse" }).path.competence_target, { t = 4, p = 3.5 })
  local function refused(patch)
    local d = ops({ { op = "path_set", id = "lib.nvim/signale", patch = patch } })
    return d.results[1].ok == false and d.results[1].error.code or "accepted"
  end
  eq(refused({ competence = { "lib.nvim/nope" } }), "invalid_argument", "an unknown competence")
  eq(refused({ competence = { "kein-id" } }), "invalid_argument")
  eq(refused({ competence_target = { t = 9 } }), "invalid_argument")
  eq(refused({ competence_target = { t = 2.25 } }), "invalid_argument")
  eq(refused({ competence_target = { x = 1 } }), "invalid_argument")
  eq(refused({ competence_target = "viel" }), "invalid_argument")

  -- a line the frontmatter writer refuses (a map of another key) is refused without the path of this machine
  local odd = root .. "/lib.nvim/ROADMAP/paths/odd-map.md"
  H.write(odd, "---\ntitle: Odd\nstatus: doing\ntags: {a: 1}\n---\n\nText.\n")
  local od = ops({ { op = "path_set", id = "lib.nvim/odd-map", patch = { tags = { "x" } } } })
  eq(od.results[1].ok, false, vim.inspect(od))
  local msg = od.results[1].error.message
  ok(not msg:find(root, 1, true), "no path of this machine: " .. msg)
  ok(not msg:find(root:gsub("/", "\\"), 1, true), "nor in backslashes: " .. msg)
  os.remove(odd)

  -- check: the broken competence file, a path naming an unknown one, a malformed field of a path
  local file = root .. "/lib.nvim/ROADMAP/paths/signale.md"
  H.write(
    file,
    (H.read(file):gsub("status: planning", "status: planning\ncompetence: lib.nvim/fehlt"))
  )
  local chk = call("check", { area = "lib.nvim" })
  local codes = {}
  for _, f in ipairs(chk.findings or chk.items or {}) do
    codes[f.code] = (codes[f.code] or 0) + 1
  end
  eq(codes["competence-unknown"], 1, vim.inspect(codes))
  eq(codes["competence-bad-level"], 1)
  eq(codes["competence-unknown-field"], 1)
  H.write(file, (H.read(file):gsub("competence: lib.nvim/fehlt", "competence_target: {t: 11}")))
  local paths2 = call("paths")
  for _, it in ipairs(paths2.items) do
    if it.id == "lib.nvim/signale" then
      eq(it.valid, false)
      has(it.problems[1], "competence_target")
    end
  end

  -- ── the command line ──────────────────────────────────────────────────────
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
    return code, vim.trim(table.concat(out, "\n")), table.concat(err, "\n")
  end
  local code, out, err = run({ "competences" })
  eq(code, 0, err)
  has(
    out,
    "lib.nvim/betriebssysteme\tT 3\tP 1\t12: 4\t24: T5/P4.5\tlib.nvim/prozesse\tBetriebssysteme"
  )
  has(out, "lib.nvim/netze\tT -\tP -\t12: -\t24: -\t-\tNetze")
  has(err, "warn: lib.nvim/netze: unknown field 'level'")
  code, out = run({ "competences", "--format=json" })
  eq(code, 0)
  eq(vim.json.decode(out).kind, "tasks.competences")
  eq((run({ "competences", "--format=xml" })), 2)
end
