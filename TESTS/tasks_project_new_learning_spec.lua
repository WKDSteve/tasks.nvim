-- TESTS/tasks_project_new_learning_spec.lua -- `project-new --template=learning`: a curriculum of learning paths with
-- goal, `## Lernpfade` holding the generated overview block of the project (scope its slug, `overview=<id>`, the id of
-- the slug it got, also a `-2` one), `## Takt` and a definition of done, no stages proposed; `projects --of=<id>
-- --write=<the file>` fills the block with the table of its paths; the write door takes `template` for `project_new`.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local ops_mod = require("tasks_nvim.ops")
  local paths = require("tasks_nvim.paths")
  local plans = require("tasks_nvim.plans")
  local projects = require("tasks_nvim.projects")

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

  -- ── the CLI makes the curriculum ──
  local code, out, err =
    run({ "project-new", A, "Rust-Stack", "--template=learning", "--areas=lib.nvim" })
  eq(code, 0, err)
  local id = A .. "/rust-stack"
  has(out, "created\t" .. id .. "\t")
  local file = root .. "/" .. A .. "/ROADMAP/projects/rust-stack.md"
  local text = H.read(file)
  for _, heading in ipairs({
    "## Ziel und Abgrenzung",
    "## Lernpfade",
    "## Takt",
    "## Definition of done",
    "## Entscheidungen",
    "## Notizen",
  }) do
    has(text, "\n" .. heading .. "\n", heading)
  end
  has(text, "<!-- GENERATED:plan scope=rust-stack overview=" .. id .. " start -->\n")
  has(text, "\n<!-- GENERATED:plan end -->\n")
  has(text, "Noch keine Pläne und keine Lernpfade.")
  lacks(text, plans.OVERVIEW_SLOT, "the slot line is never written")
  lacks(text, "phase_order", "a curriculum proposes no stages")
  local proj = assert(projects.find(id, o))
  eq(proj.valid, true, vim.inspect(proj.errors))

  -- the generated block is current as made: --check says so
  code, out = run({ "projects", "--of=" .. id, "--write=" .. file, "--check" })
  eq(code, 0, out)
  has(out, "current")

  -- a path joins; the block of the file itself takes its table
  assert(paths.new(A, vim.tbl_extend("force", o, { title = "A Rust-Kern", project = id })))
  code, out = run({ "projects", "--of=" .. id, "--write=" .. file, "--check" })
  eq(code, 1)
  has(out, "stale")
  code, out, err = run({ "projects", "--of=" .. id, "--write=" .. file })
  eq(code, 0, err)
  has(out, "written")
  text = H.read(file)
  has(text, "| `" .. A .. "/a-rust-kern` A Rust-Kern | planning | 0 | 0 | 0 % |")
  lacks(text, "Noch keine Pläne und keine Lernpfade.")
  has(text, "## Takt", "the hand-written sections stay")

  -- ── a taken slug: the block names the id the file got ──
  code, out, err = run({ "project-new", A, "Rust-Stack", "--template=learning" })
  eq(code, 0, err)
  has(out, "created\t" .. id .. "-2\t")
  local second = H.read(root .. "/" .. A .. "/ROADMAP/projects/rust-stack-2.md")
  has(second, "<!-- GENERATED:plan scope=rust-stack-2 overview=" .. id .. "-2 start -->")

  -- a plain project keeps its sections, without a block
  local _
  code, _, err = run({ "project-new", A, "Schlicht" })
  eq(code, 0, err)
  local plain = H.read(root .. "/" .. A .. "/ROADMAP/projects/schlicht.md")
  lacks(plain, "GENERATED:plan")
  has(plain, "## Ziel und Abgrenzung")

  -- ── the write door: project_new takes template; a dry run writes nothing ──
  local doc = assert(ops_mod.run({
    ops = { { op = "project_new", area = A, title = "Lua-Kurs", template = "learning" } },
    dry_run = true,
  }, o))
  eq(doc.results[1].outcome, "would_create", vim.inspect(doc.results[1]))
  ok(
    not vim.uv.fs_stat(root .. "/" .. A .. "/ROADMAP/projects/lua-kurs.md"),
    "a dry run writes nothing"
  )
  doc = assert(ops_mod.run({
    ops = { { op = "project_new", area = A, title = "Lua-Kurs", template = "learning" } },
  }, o))
  eq(doc.results[1].outcome, "created", vim.inspect(doc.results[1]))
  has(
    H.read(root .. "/" .. A .. "/ROADMAP/projects/lua-kurs.md"),
    "overview=" .. A .. "/lua-kurs start -->"
  )
  doc = assert(ops_mod.run({
    ops = { { op = "project_new", area = A, title = "X", template = "nope" } },
  }, o))
  eq(doc.results[1].ok, false)
  eq(doc.results[1].error.code, "invalid_argument")
end
