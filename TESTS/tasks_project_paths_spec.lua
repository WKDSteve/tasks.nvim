-- TESTS/tasks_project_paths_spec.lua -- a project shows its learning paths: `tasks paths [<area>] [--project=]` (id,
-- status, points, open points, percent, title; the finished paths of a project at 100 %), `tasks projects` counts the
-- paths (`paths 1/3 50 %`), and the generated overview of a project (`projects --of= --write=`) has a table of its
-- paths (and none of plans when it has paths only). `lernlevel.percent` is the progress `evaluate` reads.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local lernbaum = require("tasks_nvim.lernbaum")
  local lernlevel = require("tasks_nvim.lernlevel")
  local paths = require("tasks_nvim.paths")
  local plans = require("tasks_nvim.plans")

  -- ── lernlevel.percent: of the XP when there is any, else of the points (seen counts half) ──
  local no_xp = lernbaum.parse(
    "## Lernpunkte\n- [x] a\n- [~] b – Grund: kurz\n- [ ] c\n- [-] d – Grund: weg\n"
  )
  eq({ lernlevel.percent(no_xp) }, { 50, 3 })
  local with_xp = lernbaum.parse("## Lernpunkte\n- [x] a {xp=30}\n- [ ] b {xp=70}\n")
  eq({ lernlevel.percent(with_xp) }, { 30, 100 })
  eq({ lernlevel.percent(lernbaum.parse("")) }, { 0, 0 })

  local TODAY = "2026-11-21"
  local root = F.vault(H)
  local A = "lib.nvim"
  local o = { root = root, today = TODAY }

  ---@param argv string[]
  ---@return integer code
  ---@return string out
  ---@return string err
  local function run(argv)
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
    return code, table.concat(out), table.concat(err)
  end

  local project =
    assert(plans.new(A, vim.tbl_extend("force", o, { kind = "project", title = "Rust-Stack" })))
  ---@param title string
  ---@param tree string[]
  ---@param in_project? boolean
  ---@return string id
  local function path(title, tree, in_project)
    local made = assert(paths.new(
      A,
      vim.tbl_extend("force", o, {
        title = title,
        project = in_project ~= false and project.id or nil,
      })
    ))
    local text = H.read(made.path)
    local head = text:match("^(%-%-%-\n.-\n%-%-%-\n)")
    H.write(made.path, head .. "\n## Lernpunkte\n\n" .. table.concat(tree, "\n") .. "\n")
    return made.id
  end
  local a = path("Block A", { "- [x] eins", "- [x] zwei", "- [ ] drei", "- [ ] vier" })
  local b = path("Block B", { "- [ ] eins {xp=10}", "- [ ] zwei {xp=10}" })
  local c = path("Block C", { "- [x] fertig" })
  local loose = path("Nebenbei", { "- [x] ja", "- [ ] nein" }, false)
  assert(paths.close(c, o))

  -- ── paths: every open path, in area order ──
  local code, out, err = run({ "paths" })
  eq(code, 0, err)
  local lines = vim.split(out, "\n", { plain = true, trimempty = true })
  eq(lines, {
    a .. "\tplanning\tpoints 4\topen 2\t50 %\tBlock A",
    b .. "\tplanning\tpoints 2\topen 2\t0 %\tBlock B",
    loose .. "\tplanning\tpoints 2\topen 1\t50 %\tNebenbei",
  })

  -- --project: its paths, the finished one at 100 %; another area shows none of them
  code, out, err = run({ "paths", "--project=" .. project.id })
  eq(code, 0, err)
  eq(vim.split(out, "\n", { plain = true, trimempty = true }), {
    a .. "\tplanning\tpoints 4\topen 2\t50 %\tBlock A",
    b .. "\tplanning\tpoints 2\topen 2\t0 %\tBlock B",
    c .. "\tdone\tpoints 0\topen 0\t100 %\tBlock C",
  })
  code, out = run({ "paths", "cascade.nvim" })
  eq(code, 0)
  eq(out, "")
  -- none in JSON is an empty list, not an object
  code, out = run({ "paths", "cascade.nvim", "--format=json" })
  eq(code, 0)
  eq(vim.trim(out), '{"paths":[]}')
  code, out, err = run({ "paths", A, "--format=json" })
  eq(code, 0, err)
  local doc = vim.json.decode(out)
  eq(#doc.paths, 3)
  eq(doc.paths[1].id, a)
  eq(doc.paths[1].percent, 50)

  -- usage and an unknown project
  local _
  code, _, err = run({ "paths", "--format=md" })
  eq(code, 2)
  has(err, "usage: paths")
  code, _, err = run({ "paths", "--project=" .. A .. "/kein-projekt" })
  eq(code, 1)
  has(err, "no such open project")

  -- ── projects: the paths of each project, finished/all and the mean progress ──
  code, out, err = run({ "projects", A })
  eq(code, 0, err)
  has(out, project.id .. "\tplanning\t")
  has(out, "\tplans 0/0\ttasks 0/0\t")
  has(out, "\tpaths 1/3 50 %", "(50 + 0 + 100) / 3")

  -- ── the overview of the project: a table of its paths, none of plans ──
  local doc_path = root .. "/overview.md"
  H.write(
    doc_path,
    "# Rust\n\n<!-- GENERATED:plan scope=rust-stack overview="
      .. project.id
      .. " start -->\n<!-- GENERATED:plan end -->\n"
  )
  code, out, err = run({ "projects", "--of=" .. project.id, "--write=" .. doc_path })
  eq(code, 0, err)
  has(out, "written")
  local text = H.read(doc_path)
  has(text, "| Learning path | Status | Points | Open | Progress |")
  has(text, "| `" .. a .. "` Block A | planning | 4 | 2 | 50 % |")
  has(text, "| `" .. b .. "` Block B | planning | 2 | 2 | 0 % |")
  has(text, "| `" .. c .. "` Block C | done | - | - | 100 % |")
  lacks(text, "| Stage | Plan |", "a project with paths only shows no table of plans")
  lacks(text, loose, "a path of no project is not in it")

  -- a plan of the project brings the table of plans back, above the paths
  assert(plans.new(A, vim.tbl_extend("force", o, { title = "Umbau", project = project.id })))
  code, _, err = run({ "projects", "--of=" .. project.id, "--write=" .. doc_path })
  eq(code, 0, err)
  text = H.read(doc_path)
  local plans_at = text:find("| Stage | Plan |", 1, true)
  local paths_at = text:find("| Learning path |", 1, true)
  ok(plans_at and paths_at and plans_at < paths_at, text)
end
