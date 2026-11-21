-- TESTS/tasks_path_stats_spec.lua -- the XP overview of a learning path (`path_stats.compute`, `tasks path <id>`):
-- points in all, open and without XP, XP in all and per stage, and for each level the point at which it is reached
-- when the points are learned in order (XP, percent, the path line, a threshold of 0, one out of reach); a promoted
-- task counts with its `xp:`; a dropped point is left out; a tree without XP counts its points; the usage errors.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local lernbaum = require("tasks_nvim.lernbaum")
  local lernlevel = require("tasks_nvim.lernlevel")
  local mutate = require("tasks_nvim.mutate")
  local stats = require("tasks_nvim.path_stats")

  local TODAY = "2026-11-20"

  -- ── pure: two stages, a dropped point, a point without XP ─────────────────
  local BODY = table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [ ] Stufe 0 · Orientieren {#s0}",
    "  - [x] Notiz lesen {xp=10} {#notiz}",
    "  - [ ] Skizze {xp=30} {#skizze}",
    "  - [-] Altes Video – Grund: veraltet {xp=50}",
    "- [ ] Stufe 1 · Grundlagen {#s1}",
    "  - [ ] Kurs {xp=40} {#kurs}",
    "  - [ ] Glossar {#glossar}",
    "  - [ ] Übung {xp=20} {#uebung}",
    "",
    "## Level",
    "",
    "- [ ] 0 XP · Start",
    "- [ ] 40 XP · Erster Blick",
    "- [ ] 50 % · Halb",
    "- [ ] 200 XP · Zu viel",
    "- [ ] Pfad fertig · Alles",
    "",
  }, "\n")
  local tree = lernbaum.parse(BODY)
  local lv = lernlevel.parse(BODY)
  eq(#lv.problems, 0, vim.inspect(lv.problems))
  local st = stats.compute(tree, lv)
  eq(st.points, {
    total = 6,
    open = 4,
    learned = 1,
    seen = 0,
    dropped = 1,
    blocked = 0,
    without_xp = 1,
    counted = 5,
  })
  eq(st.xp, { total = 100, earned = 10, open = 90 }, "the dropped 50 XP are out of the sum")
  eq(#st.stages, 2)
  eq(
    { st.stages[1].label, st.stages[1].xp, st.stages[1].points, st.stages[1].open },
    { "Stufe 0 · Orientieren", 40, 3, 1 }
  )
  eq({ st.stages[2].xp, st.stages[2].points, st.stages[2].without_xp }, { 60, 3, 1 })
  eq(#st.without_xp, 1)
  eq({ st.without_xp[1].key, st.without_xp[1].stage }, { "glossar", 2 })
  eq(st.level, 1, "the 0 XP level is reached now")

  local by = {}
  for _, l in ipairs(st.levels) do
    by[l.ref] = l
  end
  eq(by["1"].at_start, true, "a threshold of 0 is reached before the first point")
  eq(by["1"].at, nil)
  -- 10 + 30 = 40 after the second point
  eq({ by["2"].at.key, by["2"].at.index, by["2"].at.stage }, { "skizze", 2, 1 })
  eq(by["2"].reached, false)
  -- 50 % of 100: 10 + 30 + 40 = 80 after the third counted point, the first of stage 2
  eq(by["3"].needed, 50)
  eq({ by["3"].at.key, by["3"].at.index, by["3"].at.stage }, { "kurs", 3, 2 })
  eq(by["4"].at, nil, "200 XP are more than the path has")
  eq(by["4"].at_start, false)
  eq({ by.done.kind, by.done.at.key, by.done.at.index }, { "done", "uebung", 5 })

  -- ── pure: a tree without XP counts points ──────────────────────────────────
  local PLAIN = table.concat({
    "## Lernpunkte",
    "- [ ] A",
    "- [ ] B",
    "- [ ] C",
    "- [ ] D",
    "## Level",
    "- [ ] 50 % · Halb",
    "- [ ] 10 XP · Nie",
    "",
  }, "\n")
  local plain = stats.compute(lernbaum.parse(PLAIN), lernlevel.parse(PLAIN))
  eq(plain.has_xp, false)
  eq(#plain.stages, 4, "a root without children is a stage of one point")
  eq(plain.levels[1].needed, 2)
  eq(plain.levels[1].at.label, "B", "2 of 4 points are 50 %")
  eq(plain.levels[2].at, nil, "a level in XP is out of reach without XP")
  -- no levels: only the counts
  local bare = stats.compute(lernbaum.parse(PLAIN), nil)
  eq(#bare.levels, 0)
  eq(bare.points.total, 4)

  -- ── the command line: a promoted task counts with its xp ──────────────────
  local root = F.vault(H)
  local A = "lib.nvim"
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local cc = assert(mutate.new(A, vim.tbl_extend("force", o, { title = "C-Compiler", xp = 60 })))
  H.write(
    root .. "/" .. A .. "/ROADMAP/paths/lua-lernen.md",
    table.concat({
      "---",
      "title: Lua lernen",
      "status: doing",
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [ ] Grundlagen {#g}",
      "  - [x] Manual {xp=20} {#manual}",
      "  - [ ] C-Compiler → " .. cc.id .. " {xp=5} {#cc}",
      "  - [ ] Notizen {#notizen}",
      "",
      "## Level",
      "",
      "- [ ] 50 XP · Bronze",
      "- [ ] Pfad fertig · Gold",
      "",
    }, "\n")
  )

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

  local code, out, err = run({ "path", A .. "/lua-lernen" })
  eq(code, 0, err)
  has(out, "path\t" .. A .. "/lua-lernen\tdoing\tLua lernen")
  has(out, "points\t3\topen 2\tlearned 1\tseen 0\tdropped 0\twithout xp 1")
  has(out, "xp\t80\tearned 20\topen 60", "the task's 60 XP, not the point's 5")
  has(out, "stage\t1\txp 80\tpoints 3\topen 2\twithout xp 1\tGrundlagen")
  has(out, "level\t1\t50 XP\tBronze\topen\tat point 2/3, stage 1: #cc C-Compiler")
  has(out, "level\tdone\tpath done\tGold\topen\tat point 3/3, stage 1: #notizen Notizen")
  has(out, "without-xp\tstage 1\t#notizen Notizen")

  code, out, err = run({ "path", A .. "/lua-lernen", "--format=json" })
  eq(code, 0, err)
  local doc = vim.json.decode(out)
  eq(doc.xp.total, 80)
  eq(doc.levels[1].at.key, "cc")
  eq(doc.stages[1].xp, 80)

  -- usage errors and an unknown path
  local _
  code, _, err = run({ "path" })
  eq(code, 2)
  has(err, "usage: path <area>/<slug>")
  code = run({ "path", A .. "/lua-lernen", "--format=tsv" })
  eq(code, 2)
  code, _, err = run({ "path", A .. "/nope" })
  eq(code, 1)
  ok(err ~= "", "an unknown path is an error")
end
