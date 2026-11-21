-- TESTS/tasks_lernbaum_optional_spec.lua -- optional subtrees of a learning tree (`{optional}`): read and written back,
-- left out of the progress, the levels in percent and the path being finished, their XP counted once earned; `tasks
-- path`, the heading of `:Tasks learn` and the learning template.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local lb = require("tasks_nvim.lernbaum")
  local lernlevel = require("tasks_nvim.lernlevel")
  local stats = require("tasks_nvim.path_stats")

  local TEXT = table.concat({
    "## Lernpunkte",
    "",
    "- [ ] Stufe 1 {#s1}",
    "  - [x] A {xp=10} {#a}",
    "  - [ ] B {xp=10} {#b}",
    "  - [ ] Extra {#extra} {optional}",
    "    - [x] E1 {xp=4}",
    "    - [ ] E2 {optional} {xp=4} {#e2}",
    "- [ ] Literatur {optional} {#lit}",
    "  - [x] Buch 1 {xp=5} {#b1}",
    "  - [~] Buch 2 \226\128\147 Grund: nur ein Kapitel {xp=6}",
    "  - [ ] Buch 3 {xp=5}",
    "",
    "## Level",
    "",
    "- [ ] 20 XP \194\183 Zwanzig",
    "- [ ] 50 % \194\183 Halb",
    "- [ ] Pfad fertig",
    "",
  }, "\n")

  -- ── reading: the mark in any order with key and XP, inherited by the subtree ──
  local t = lb.parse(TEXT)
  eq(t.problems, {})
  eq(t.has_optional, true)
  local lit, extra = t.by_key.lit, t.by_key.extra
  eq({ lit.optional, lit.label, lit.key }, { true, "Literatur", "lit" })
  eq({ extra.optional, extra.label }, { true, "Extra" })
  eq({ t.by_key.e2.optional, t.by_key.e2.xp, t.by_key.e2.label }, { true, 4, "E2" })
  eq(t.by_key.b1.optional, nil, "the mark of the group is not written on its children")
  eq(t.by_key.b1.in_optional, true, "but they are optional")
  eq(t.by_key.a.in_optional, false)
  eq(t.by_key.s1.in_optional, false)
  -- a label that only says "optional" in words is no mark
  eq(lb.parse("## Lernpunkte\n- [ ] Literatur (optional)\n").nodes[1].optional, nil)

  -- ── counting: the progress and the XP leave the optional points out ─────────
  eq(t.progress, { learned = 1, seen = 0, dropped = 0, open = 1, blocked = 0, total = 2 })
  eq(t.xp, { earned = 10, possible = 20, open = 10, points = 2, missing = 0 })
  eq(t.optional.progress, { learned = 2, seen = 1, dropped = 0, open = 2, blocked = 0, total = 5 })
  eq(t.optional.xp, { earned = 4 + 5 + 3, possible = 24, open = 9, points = 5, missing = 0 })
  -- a node shows its whole subtree; the stage is closed by its points that are not optional
  eq(t.by_key.s1.progress.total, 4)
  eq(t.by_key.s1.derived, "partial")
  eq(lit.progress.total, 3)
  eq(lit.closed, false, "an optional group by its own points")

  -- ── levels: percent and the path's line without them, XP with the ones earned ──
  local lv = lernlevel.parse(TEXT)
  local st = lernlevel.evaluate(lv, t)
  eq(st.percent, 50, "10 of 20 XP that count")
  eq(st.reached["1"], true, "10 + 12 optional XP earned are 20 XP")
  eq(st.reached["2"], true)
  eq(st.finished, false, "B is open")
  -- B learned: the path is finished, though books are open
  local done = lb.parse((TEXT:gsub("%- %[ %] B ", "- [x] B ")))
  local st2 = lernlevel.evaluate(lv, done)
  eq({ st2.finished, st2.reached.done, st2.percent }, { true, true, 100 })
  eq(done.by_key.s1.closed, true, "a stage is closed though its optional group is open")
  eq(done.by_key.s1.derived, "learned")
  -- not enough without the books: an XP level counts the optional XP only once earned
  local unread =
    lb.parse((TEXT:gsub("%[x%] Buch 1", "[ ] Buch 1"):gsub("%[~%] Buch 2", "[ ] Buch 2")))
  eq(lernlevel.evaluate(lv, unread).reached["1"], false, "10 + 4 XP are not 20")
  -- a tree whose XP are all optional counts its points for percent
  local only_opt =
    lb.parse("## Lernpunkte\n- [x] A\n- [ ] B\n- [ ] Lit {optional}\n  - [x] L {xp=9}\n")
  eq(only_opt.has_xp, true)
  eq(lernlevel.percent(only_opt), 50)

  -- ── writing: a change keeps the mark ───────────────────────────────────────
  local w = lb.parse(TEXT)
  ok(lb.set_state(w, "e2", "learned"))
  has(lb.render(w), "    - [x] E2 {xp=4} {optional} {#e2}\n")
  ok(lb.set_xp(w, "e2", 7))
  has(lb.render(w), "    - [x] E2 {xp=7} {optional} {#e2}\n")
  eq(lb.parse(lb.render(w)).by_key.e2.optional, true)

  -- ── tasks path: the optional points apart, the forecast without them ───────
  local s = stats.compute(t, lv)
  eq(s.points.total, 2)
  eq(s.xp, { total = 20, earned = 10, open = 10 })
  eq(s.optional, { points = 5, open = 2, learned = 2, seen = 1, dropped = 0, xp = 24, earned = 12 })
  eq({ s.stages[1].points, s.stages[1].xp, s.stages[1].optional }, { 2, 20, nil })
  eq({ s.stages[2].points, s.stages[2].xp, s.stages[2].optional }, { 3, 16, true })
  local by = {}
  for _, l in ipairs(s.levels) do
    by[l.ref] = l
  end
  eq(by.done.at.key, "b", "the path is done at the last point that counts")
  eq(by["2"].needed, 10)
  eq(stats.compute(lb.parse("## Lernpunkte\n- [ ] A {xp=3}\n"), nil).optional, nil)

  -- the command line
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local root = F.vault(H)
  H.write(
    root .. "/lib.nvim/ROADMAP/paths/opt.md",
    "---\ntitle: Opt\nstatus: doing\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\n" .. TEXT
  )
  local out, err = {}, {}
  local code = require("tasks_nvim.cli").run(
    { "path", "lib.nvim/opt", "--vault=" .. root, "--today=" .. F.TODAY },
    {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    }
  )
  local text = table.concat(out)
  eq(code, 0, table.concat(err))
  has(text, "points\t2\topen 1\t")
  has(text, "optional\t5\topen 2\tlearned 2\tseen 1\tdropped 0\txp 24\tearned 12\n")
  has(text, "stage\t2\txp 16\tpoints 3\topen 1\twithout xp 0\tLiteratur\toptional\n")
  has(text, "level\tdone\tpath done")
  has(text, "at point 2/2")

  -- ── :Tasks learn: the heading names them ───────────────────────────────────
  local learn = require("tasks_nvim.ui.learn")
  eq(learn.optional_text(t), "optional 2/5 gelernt (12 XP)")
  eq(learn.optional_text(lb.parse("## Lernpunkte\n- [ ] A\n")), "")

  -- ── the learning template marks the literature group ───────────────────────
  local made = assert(
    require("tasks_nvim.paths").new(
      "lib.nvim",
      { root = root, today = F.TODAY, title = "Vorlage", template = "learning" }
    )
  )
  has(
    H.read(made.path),
    "Hintergrund aus der Literatur (je Buch nur das Kapitel zur Frage) {optional} {#literatur}"
  )
end
