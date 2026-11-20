-- TESTS/tasks_lernbaum_xp_spec.lua -- XP of the learning tree: `{xp=N}` beside `{#key}` read in either order and
-- written back byte for byte, learned full / seen half / dropped out of sum and maximum, parents summing their
-- children, the XP of a promoted task, bad XP as a problem, set_xp, and a tree without XP as before.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local lb = require("tasks_nvim.lernbaum")

  local LUA = table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lua lernen {#lua}",
    "  - [ ] Syntax erlernen {#syntax}",
    "    - [x] [Lua 5.4 Reference Manual, Kap. 3](https://www.lua.org/manual/5.4/) {xp=20}",
    "      > Notiz: Operatorrangfolge von `..` und `^` merken.",
    "    - [~] [Programming in Lua](https://www.lua.org/pil/) – Grund: nur Kap. 1 gebraucht {#pil} {xp=15}",
    "    - [ ] ![Syntaxdiagramm](assets/images/lua-syntax.svg) {xp=10}",
    "  - [ ] C-Compiler erlernen → learning/c-compiler {xp=40} {#cc}",
    "  - [-] Lua-JIT-Interna – Grund: für das Ziel nicht nötig {xp=30}",
    "  - [ ] Ohne XP",
    "",
  }, "\n")

  -- ── reading: the XP of each leaf, in either order with the key ──
  local t = lb.parse(LUA)
  eq(#t.problems, 0, vim.inspect(t.problems))
  eq(t.has_xp, true)
  local syntax = t.by_key.syntax
  eq(syntax.children[1].xp, 20)
  eq(
    syntax.children[1].label,
    "[Lua 5.4 Reference Manual, Kap. 3](https://www.lua.org/manual/5.4/)"
  )
  eq(t.by_key.pil.xp, 15, "the XP after the key is read too")
  eq(t.by_key.pil.reason, "nur Kap. 1 gebraucht", "the XP is not part of the reason")
  eq(t.by_key.cc.xp, 40)
  eq(t.by_key.cc.promoted, "learning/c-compiler")
  eq(t.by_key.cc.xp_from, "point")

  -- ── counting: learned full, seen half (rounded down), dropped out of both, open 0 ──
  eq(syntax.xp_progress, { earned = 27, possible = 45, open = 10, points = 3, missing = 0 })
  eq(
    t.xp,
    { earned = 27, possible = 85, open = 50, points = 4, missing = 1 },
    "dropped 30 is in no sum"
  )
  eq(t.by_key.lua.xp_progress, t.xp, "a parent sums its children")
  eq(t.progress.learned, 1, "the counts are as before")

  -- ── writing back: untouched lines byte for byte, a changed line keeps its XP ──
  eq(lb.render(t), LUA)
  local crlf = LUA:gsub("\n", "\r\n")
  eq(lb.render(lb.parse(crlf)), crlf)
  local n = assert(lb.set_state(t, "cc", "learned"))
  eq(n.xp, 40)
  eq(t.xp.earned, 67)
  local out = lb.render(t)
  ok(out:find("  - [x] C-Compiler erlernen → learning/c-compiler {xp=40} {#cc}", 1, true), out)

  -- ── a promoted task's XP wins over the point's; without it the point's counts ──
  lb.set_task_xp(t, { ["learning/c-compiler"] = 60 })
  eq(t.by_key.cc.xp, 60)
  eq(t.by_key.cc.xp_from, "task")
  eq(t.xp.earned, 87)
  lb.set_task_xp(t, { ["learning/c-compiler"] = false })
  eq(t.by_key.cc.xp, 40)
  eq(t.xp.earned, 67)

  -- ── set_xp: write, change, remove; a parent has none ──
  local t2 = lb.parse(LUA)
  assert(lb.set_xp(t2, "#8", 5))
  ok(lb.render(t2):find("  - [ ] Ohne XP {xp=5}", 1, true))
  eq(t2.xp.missing, 0)
  assert(lb.set_xp(t2, "#8", nil))
  eq(lb.render(t2), LUA, "removing the XP gives the text back")
  local _, perr = lb.set_xp(t2, "syntax", 5)
  ok(perr and perr:find("children", 1, true), perr)
  local _, xerr = lb.set_xp(t2, "#8", -1)
  ok(xerr and xerr:find("whole number", 1, true), xerr)
  eq(select(2, lb.set_xp(t2, "#8", 100001)) ~= nil, true, "more than MAX_XP is refused")

  -- ── bad XP and XP on a parent are problems; the bad text stays as written ──
  local bad = lb.parse(table.concat({
    "## Lernpunkte",
    "- [ ] Eltern {xp=10} {#p}",
    "  - [x] Kind {xp=abc}",
    "  - [x] Kind 2 {xp=3.5}",
  }, "\n"))
  local codes = {}
  for _, p in ipairs(bad.problems) do
    codes[#codes + 1] = p.code .. "@" .. p.line
  end
  table.sort(codes)
  eq(codes, { "path-bad-xp@2", "path-bad-xp@3", "path-bad-xp@4" })
  eq(bad.by_key.p.xp, nil, "a parent's own XP counts nothing")
  eq(bad.has_xp, false)
  assert(lb.set_state(bad, "#2", "open"))
  ok(lb.render(bad):find("  - [ ] Kind {xp=abc}", 1, true), "a bad XP is written back as it was")

  -- ── to_xp ──
  eq(lb.to_xp("25"), 25)
  eq(lb.to_xp(0), 0)
  eq(lb.to_xp(2.5), nil)
  eq(lb.to_xp("1e3"), nil)
  eq(lb.to_xp(" 5"), nil)
  eq(lb.to_xp(math.huge), nil)

  -- ── a tree without XP works as before ──
  local plain = lb.parse("## Lernpunkte\n- [x] a\n- [ ] b\n")
  eq(plain.has_xp, false)
  eq(plain.xp, { earned = 0, possible = 0, open = 0, points = 0, missing = 2 })
end
