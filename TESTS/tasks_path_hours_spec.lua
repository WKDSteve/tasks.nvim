-- TESTS/tasks_path_hours_spec.lua -- the hours of a learning path (`learn.hours`, `learn.point_hours`, capability
-- `path_hours`): planned spans, done, open; the outermost point counts, never an inner one too; a point dropped in full
-- plans nothing, a closed one leaves nothing open; optional points count for nothing; sums kept to two places; no
-- field without hours. The documents themselves are the golden `path-hours`.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local G = dofile(here .. "/contract_golden.lua")
  local api = require("tasks_nvim.api")
  local learn = require("tasks_nvim.learn")
  local lernbaum = require("tasks_nvim.lernbaum")

  local function hours(lines)
    return learn.hours(lernbaum.parse("## Lernpunkte\n\n" .. table.concat(lines, "\n") .. "\n"))
  end

  eq(hours({ "- [ ] Ohne Stunden" }), nil, "no field without hours")
  eq(learn.hours(lernbaum.parse("")), nil)
  eq(hours({ "- [ ] Eins {h=2}", "- [ ] Zwei {h=3-5}" }), {
    planned_min = 5,
    planned_max = 7,
    done = 0,
    open_min = 5,
    open_max = 7,
  })
  -- the outer point counts, its inner hours are part of it
  eq(
    hours({
      "- [ ] Woche {h=10} {done_h=4}",
      "  - [ ] Teil {h=6} {done_h=3}",
      "  - [ ] Rest",
    }),
    { planned_min = 10, planned_max = 10, done = 4, open_min = 6, open_max = 6 }
  )
  -- an inner point counts when nothing above it carries hours
  eq(
    hours({ "- [ ] Stufe", "  - [ ] Teil {h=1.5}", "  - [ ] Teil {h=1,5}" }),
    { planned_min = 3, planned_max = 3, done = 0, open_min = 3, open_max = 3 }
  )
  -- closed: nothing open, done stays; more done than planned: nothing open, never below 0
  eq(
    hours({ "- [x] Fertig {h=4} {done_h=6}", "- [ ] Offen {h=2} {done_h=5}" }),
    { planned_min = 6, planned_max = 6, done = 11, open_min = 0, open_max = 0 }
  )
  -- dropped in full: no plan; dropped in part: the plan stays
  eq(
    hours({
      "- [-] Weg – Grund: veraltet {h=8}",
      "- [ ] Teils {h=4}",
      "  - [-] Weg – Grund: x",
      "  - [ ] Bleibt",
    }),
    { planned_min = 4, planned_max = 4, done = 0, open_min = 4, open_max = 4 }
  )
  -- optional points count for nothing, but their hours say the path has hours
  eq(
    hours({ "- [ ] Extras {optional}", "  - [ ] Buch {h=9}" }),
    { planned_min = 0, planned_max = 0, done = 0, open_min = 0, open_max = 0 }
  )
  -- two places at most
  eq(
    hours({ "- [ ] A {h=0.1}", "- [ ] B {h=0.2}" }).planned_min,
    0.3,
    "0.1 + 0.2 is 0.3, not 0.30000000000000004"
  )

  -- ── the documents ─────────────────────────────────────────────────────────
  local root = F.vault(H)
  G.write_learn_paths(root)
  local function call(method, params)
    return vim.json.decode((api.call(method, { params = params }, { root = root })))
  end
  ok(vim.tbl_contains(call("hello", {}).capabilities, "path_hours"))
  local paths = call("paths", {})
  local by = {}
  for _, it in ipairs(paths.items) do
    by[it.id] = it
  end
  eq(by["lib.nvim/prozesse"].hours.planned_max, 8)
  eq(by["lib.nvim/signale"].hours, nil, "a path without hours has no field")
  local doc = call("path", { id = "lib.nvim/prozesse" })
  eq(#doc.schedule, 2)
  eq(doc.schedule[1].key, "w1")
  eq(doc.schedule[1].done, 2)
  eq(doc.schedule[1].open_min, 2)
  eq(call("path", { id = "lib.nvim/signale" }).schedule, nil)
end
