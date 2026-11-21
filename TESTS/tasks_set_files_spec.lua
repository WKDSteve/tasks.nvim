-- TESTS/tasks_set_files_spec.lua -- `tasks set <id> key=value` on a learning path, a plan and a project file (no open
-- task of that id): the frontmatter of the file changes as `path_set` / `plan_set` / `project_set` change it (lists
-- with commas, an empty value removes a key, `tags` on a path), a bad change is refused and writes nothing, an open
-- task of the id still wins, an id that names nothing stays an error. `path_set` of the write door takes `tags`.
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
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end

  local project =
    assert(plans.new(A, vim.tbl_extend("force", o, { kind = "project", title = "Lernprojekt" })))
  local path = assert(paths.new(A, vim.tbl_extend("force", o, { title = "Rust lernen" })))
  local plan = assert(plans.new(A, vim.tbl_extend("force", o, { title = "Umbau", phases = "a,b" })))

  -- ── a learning path: project, status, areas, tags, links in one command ──
  local code, out, err = run({
    "set",
    path.id,
    "project=" .. project.id,
    "status=doing",
    "areas=lib.nvim,tasks.nvim",
    "tags=not-on-workstation,rust",
    "links=https://doc.rust-lang.org/book/",
  })
  eq(code, 0, err)
  has(out, "set\t" .. path.id .. "\tchanged\t")
  local got = assert(paths.find(path.id, o))
  eq(got.project, project.id)
  eq(got.status, "doing")
  eq(got.areas, { "lib.nvim", "tasks.nvim" })
  eq(got.tags, { "not-on-workstation", "rust" })
  eq(got.links, { "https://doc.rust-lang.org/book/" })

  -- the same values again change nothing; an empty value removes a key
  code, out = run({ "set", path.id, "status=doing" })
  eq(code, 0)
  has(out, "\tunchanged\t")
  local _
  code, _, err = run({ "set", path.id, "tags=", "project=" })
  eq(code, 0, err)
  got = assert(paths.find(path.id, o))
  eq(got.tags, {})
  eq(got.project, nil)

  -- a bad change is refused (exit 2) and nothing is written
  local before = H.read(path.path)
  code, _, err = run({ "set", path.id, "project=" .. A .. "/gibt-es-nicht" })
  eq(code, 2)
  has(err, "no such open project")
  code, _, err = run({ "set", path.id, "phase=a" })
  eq(code, 2)
  has(err, "unknown field 'phase'")
  code, _, err = run({ "set", path.id, "status=done" })
  eq(code, 2)
  has(err, "close")
  code, _, err = run({ "set", path.id, "title=" })
  eq(code, 2)
  has(err, "title cannot be removed")
  eq(H.read(path.path), before, "a refused change writes nothing")

  -- ── a plan and a project take their own keys ──
  code, _, err = run({ "set", plan.id, "project=" .. project.id, "gate=hard" })
  eq(code, 0, err)
  got = assert(plans.find(plan.id, o))
  eq(got.project, project.id)
  eq(got.gate, "hard")
  code, _, err = run({ "set", project.id, "status=doing", "phase_order=eins,zwei" })
  eq(code, 0, err)
  got = assert(require("tasks_nvim.projects").find(project.id, o))
  eq(got.status, "doing")
  eq(got.phase_order, { "eins", "zwei" })

  -- ── an open task keeps the command: its own keys, not a file's ──
  F.task(H, root, A, "aufgabe", F.meta("Aufgabe", "open"), "\nText.\n")
  code, out, err = run({ "set", A .. "/aufgabe", "prio=1" })
  eq(code, 0, err)
  has(out, "set\t" .. A .. "/aufgabe\tchanged\t")
  has(H.read(root .. "/" .. A .. "/ROADMAP/tasks/aufgabe.md"), "prio: 1")

  -- an id that names nothing is still the error of a task
  code, _, err = run({ "set", A .. "/nichts", "status=open" })
  eq(code, 1)
  ok(err ~= "", "an unknown id is an error")
  lacks(err, "unknown field")

  -- ── the write door: path_set takes tags, with its inverse ──
  local doc = assert(ops_mod.run({
    ops = { { op = "path_set", id = path.id, patch = { tags = { "on-workstation" } } } },
  }, o))
  local entry = doc.results[1]
  eq(entry.outcome, "changed", vim.inspect(entry))
  eq(assert(paths.find(path.id, o)).tags, { "on-workstation" })
  eq(entry.inverse.patch.tags, vim.NIL, "the path had no tags before")
end
