-- TESTS/tasks_contract_paths_spec.lua -- the learning paths in the contract (capabilities `paths`, `path`): the area
-- filter, the refusals, and a `rev` that follows the path file (the documents themselves are goldens `paths`, `path`).
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local paths = require("tasks_nvim.paths")

  local root = F.vault(H)
  local function call(method, params)
    local text = api.call(method, { params = params or {} }, { root = root, today = F.TODAY })
    local doc = vim.json.decode(text)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end

  local hello = call("hello")
  ok(vim.tbl_contains(hello.capabilities, "paths"))
  ok(vim.tbl_contains(hello.capabilities, "path"))

  -- a vault without paths: an empty list
  local none = call("paths")
  eq(none.kind, "tasks.paths")
  eq(none.items, {})

  local file = root .. "/lib.nvim/ROADMAP/paths/rust.md"
  H.write(
    file,
    "---\ntitle: Rust\nstatus: doing\n---\n\n## Lernpunkte\n\n- [ ] Ownership {#own}\n- [x] Cargo\n"
  )
  H.write(
    root .. "/cascade.nvim/ROADMAP/paths/go.md",
    "---\ntitle: Go\nstatus: planning\n---\n\n## Lernpunkte\n\n- [ ] Goroutinen\n"
  )
  local all = call("paths")
  eq(#all.items, 2)
  local lib = call("paths", { area = "lib.nvim" })
  eq(#lib.items, 1)
  eq(lib.items[1].id, "lib.nvim/rust")
  eq(
    lib.items[1].progress,
    { learned = 1, seen = 0, dropped = 0, open = 1, blocked = 0, total = 2 }
  )
  -- a status that is no word of the paths is left out of the entry (the schema names the four words)
  H.write(
    root .. "/lib.nvim/ROADMAP/paths/odd.md",
    "---\ntitle: Odd\nstatus: open\n---\n\n## Lernpunkte\n\n- [ ] Eins\n"
  )
  local odd
  for _, i in ipairs(call("paths", { area = "lib.nvim" }).items) do
    if i.id == "lib.nvim/odd" then
      odd = i
    end
  end
  ok(odd, "the odd path is listed")
  eq(odd.status, nil, "status open is no status of a path")
  os.remove(root .. "/lib.nvim/ROADMAP/paths/odd.md")
  local _, unknown = call("paths", { area = "nope.nvim" })
  eq(unknown, "not_found")

  local one = call("path", { id = "lib.nvim/rust" })
  eq(one.kind, "tasks.path")
  -- a path that starts with its learning points has no summary (never the checkbox lines as text)
  eq(one.path.summary, "")
  eq(lib.items[1].summary, "")
  eq(#one.nodes, 2)
  eq(one.nodes[1].key, "own")
  local _, missing = call("path", { id = "lib.nvim/nope" })
  eq(missing, "not_found")
  local _, bad = call("path", { id = "no-slash" })
  eq(bad, "invalid_argument")

  -- the rev follows the file: a point ticked is a new rev
  local rev = one.rev
  assert(paths.point("lib.nvim/rust", "own", "learned", nil, { root = root, today = F.TODAY }))
  local after = call("path", { id = "lib.nvim/rust" })
  ok(after.rev ~= rev, "a changed path file is a new rev")
  eq(after.progress.learned, 2)
  ok(call("paths", { area = "lib.nvim" }).rev ~= lib.rev, "and a new rev of the list")

  -- ── XP (capability `xp`): a path without XP and levels carries none of the new fields ──
  ok(vim.tbl_contains(hello.capabilities, "xp"))
  ok(vim.tbl_contains(hello.capabilities, "path_reward"))
  eq({ after.xp, after.levels, after.path.xp, after.path.level }, {})
  -- the XP of a promoted task count, and the rev follows them though the path file stays
  local mutate = require("tasks_nvim.mutate")
  local o = { root = root, today = F.TODAY }
  local task =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Borrow", xp = 30 })))
  H.write(
    file,
    "---\ntitle: Rust\nstatus: doing\n---\n\n## Lernpunkte\n\n- [ ] Borrow → "
      .. task.id
      .. " {xp=10} {#borrow}\n- [x] Cargo {xp=5}\n\n## Level\n\n- [ ] 5 XP · Belohnung: Eis\n"
  )
  local with = call("path", { id = "lib.nvim/rust" })
  eq(with.xp, { earned = 5, possible = 35, open = 30, points = 2, missing = 0 })
  eq(with.nodes[1].xp, 30)
  eq(with.nodes[1].xp_from, "task")
  eq(with.path.level.open_rewards, { { ref = "1", reward = "Eis" } })
  eq(with.levels[1].reached, true)
  local listed = call("paths", { area = "lib.nvim" })
  assert(mutate.set(task.id, { xp = "50" }, o))
  local changed = call("path", { id = "lib.nvim/rust" })
  eq(changed.nodes[1].xp, 50)
  ok(changed.rev ~= with.rev, "a task's xp changed is a new rev of the path")
  ok(call("paths", { area = "lib.nvim" }).rev ~= listed.rev, "and of the list")
  -- the task entry carries its xp
  local t = call("task", { id = task.id })
  eq(t.task.xp, 50)
end
