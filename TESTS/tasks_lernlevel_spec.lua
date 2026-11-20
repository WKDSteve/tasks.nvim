-- TESTS/tasks_lernlevel_spec.lua -- levels, badges and rewards of a learning path (`## Level`): thresholds in XP and
-- percent, the path line, the level reached and the next with the XP missing, open rewards, set_reward byte for byte,
-- the problems (bad line, order, badge outside, bad mark), a path without XP counting its points, a body without the
-- section, and the XP suggestion.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local lb = require("tasks_nvim.lernbaum")
  local ll = require("tasks_nvim.lernlevel")

  local BODY = table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lua lernen {#lua}",
    "  - [x] Manual {xp=20}",
    "  - [~] PIL – Grund: nur Kap. 1 {xp=20}",
    "  - [ ] C-Compiler → learning/c-compiler {xp=40} {#cc}",
    "  - [-] JIT – Grund: nicht nötig {xp=30}",
    "",
    "## Level",
    "",
    "- [x] 20 XP · Badge assets/badges/stern.png · Belohnung: großes Eis kaufen",
    "- [ ] 50 % · Fortgeschritten · ![mond](assets/badges/mond.svg) · Belohnung: Kino",
    "- [ ] 80 XP | Reward: a book",
    "- [ ] Pfad fertig · Belohnung: ein Wochenende am See",
    "",
  }, "\n")

  -- ── reading ──
  local lv = ll.parse(BODY)
  eq(lv.has_section, true)
  eq(#lv.problems, 0, vim.inspect(lv.problems))
  eq(#lv.levels, 3)
  local one, two, three = lv.levels[1], lv.levels[2], lv.levels[3]
  eq({ one.kind, one.threshold, one.badge, one.reward, one.given, one.ref }, {
    "xp",
    20,
    "assets/badges/stern.png",
    "großes Eis kaufen",
    true,
    "1",
  })
  eq({ two.kind, two.threshold, two.name, two.badge, two.reward }, {
    "percent",
    50,
    "Fortgeschritten",
    "assets/badges/mond.svg",
    "Kino",
  })
  eq({ three.kind, three.threshold, three.reward }, { "xp", 80, "a book" }, "| and Reward: as well")
  eq(lv.final.kind, "done")
  eq(lv.final.ref, "done")
  eq(lv.final.reward, "ein Wochenende am See")

  -- ── evaluating: 30 of 80 XP (20 learned, 10 of the seen 20; the dropped 30 out) ──
  local tree = lb.parse(BODY)
  eq(tree.xp.earned, 30)
  eq(tree.xp.possible, 80)
  local st = ll.evaluate(lv, tree)
  eq(st.has_levels, true)
  eq(st.percent, 37)
  eq(st.level, 1)
  eq(st.badge, "assets/badges/stern.png")
  eq(st.next, { number = 2, name = "Fortgeschritten", missing_xp = 10 }, "50 % of 80 is 40")
  eq(st.finished, false)
  eq(st.open_rewards, {}, "level 1 is granted already, the others are not reached")

  -- the promoted task brings 40 XP: 70 of 80, levels 1 and 2 reached, the reward of 2 open
  assert(lb.set_state(tree, "cc", "learned"))
  st = ll.evaluate(lv, tree)
  eq(st.level, 2)
  eq(st.level_name, "Fortgeschritten")
  eq(st.next, { number = 3, missing_xp = 10 })
  -- every point closed (a seen one is closed too): the path line is reached before the last level
  eq(st.finished, true)
  eq(st.open_rewards, {
    { ref = "2", reward = "Kino" },
    { ref = "done", reward = "ein Wochenende am See" },
  })
  assert(lb.set_state(tree, "#3", "learned"))
  st = ll.evaluate(lv, tree)
  eq(st.level, 3)
  eq(st.next, nil)
  eq(st.open_rewards, {
    { ref = "2", reward = "Kino" },
    { ref = "3", reward = "a book" },
    { ref = "done", reward = "ein Wochenende am See" },
  })

  -- ── set_reward: only the mark changes ──
  local body = assert(ll.set_reward(lv, 2, true))
  eq(body, (BODY:gsub("%- %[ %] 50 %%", "- [x] 50 %%")))
  body = assert(ll.set_reward(ll.parse(body), "1", false))
  ok(body:find("- [ ] 20 XP · Badge", 1, true))
  body = assert(ll.set_reward(ll.parse(BODY), "done", true))
  ok(body:find("- [x] Pfad fertig", 1, true))
  local crlf = BODY:gsub("\n", "\r\n")
  eq(
    assert(ll.set_reward(ll.parse(crlf), 2, true)),
    (crlf:gsub("%- %[ %] 50 %%", "- [x] 50 %%")),
    "CRLF stays"
  )
  eq(select(2, ll.set_reward(lv, 9, true)), "no such level: 9 (a number from 1 to 3, or done)")
  local nolv = ll.parse("## Level\n- [ ] 10 XP · Badge assets/badges/a.png\n")
  local _, rerr = ll.set_reward(nolv, 1, true)
  ok(rerr and rerr:find("no reward", 1, true), rerr)

  -- ── problems ──
  local bad = ll.parse(table.concat({
    "## Level",
    "- [ ] 50 XP · Belohnung: a",
    "- [ ] 40 XP · Belohnung: b",
    "- [ ] viel XP",
    "- [?] 60 XP",
    "- [ ] 70 XP · Badge images/x.png",
    "- [ ] Pfad fertig",
    "- [ ] Path done",
  }, "\n"))
  local codes = {}
  for _, p in ipairs(bad.problems) do
    codes[#codes + 1] = p.code .. "@" .. p.line
  end
  table.sort(codes)
  eq(codes, {
    "level-bad-line@4",
    "level-bad-line@8",
    "level-bad-mark@5",
    "level-badge-outside@6",
    "level-order@3",
  })
  -- across units, once the maximum is known: 50 % of 80 = 40 XP is not above 50 XP
  local mixed = ll.parse("## Level\n- [ ] 50 XP\n- [ ] 50 %\n")
  eq(#mixed.problems, 0)
  local mst = ll.evaluate(mixed, lb.parse(BODY))
  eq(#mst.problems, 1)
  eq(mst.problems[1].code, "level-order")
  eq(mst.problems[1].line, 3)

  -- ── a tree without XP: percent levels count the points, XP levels are not reached ──
  local plain =
    lb.parse("## Lernpunkte\n- [x] a\n- [~] b – Grund: c\n- [ ] d\n- [-] e – Grund: f\n")
  local pst = ll.evaluate(ll.parse("## Level\n- [ ] 50 % · Belohnung: Eis\n- [ ] 10 XP\n"), plain)
  eq(pst.percent, 50, "learned 1 + seen 0.5 of 3")
  eq(pst.level, 1)
  eq(pst.next, { number = 2, missing_xp = 10 })
  eq(pst.open_rewards, { { ref = "1", reward = "Eis" } })

  -- ── no section: no levels, no hints ──
  local none = ll.parse("## Lernpunkte\n- [x] a {xp=5}\n")
  eq(none.has_section, false)
  local nst = ll.evaluate(none, lb.parse("## Lernpunkte\n- [x] a {xp=5}\n"))
  eq({ nst.has_levels, nst.level, nst.next, #nst.open_rewards }, { false, 0, nil, 0 })

  -- ── the XP suggestion: effort first, else depth ──
  eq(lb.suggest_xp({ effort = "M" }), 50)
  eq(lb.suggest_xp({ effort = "XL" }), 200)
  eq(lb.suggest_xp({ effort = "2d" }), 100)
  eq(lb.suggest_xp({ effort = "0.05d" }), 5)
  eq(lb.suggest_xp({ depth = 0 }), 20)
  eq(lb.suggest_xp({ depth = 1 }), 15)
  eq(lb.suggest_xp({ depth = 3 }), 10)
  eq(lb.suggest_xp({}), 20)
end
