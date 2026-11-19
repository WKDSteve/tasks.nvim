-- TESTS/tasks_lernbaum_spec.lua -- the learning tree of `## Lernpunkte`: the fixture "Lua lernen" of the concept
-- (syntax, C compiler, nested, mixed states), the parent rule, progress counted apart, the problems of one file, a
-- byte-for-byte render (CRLF, prose, code fences), and set_state.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local lb = require("tasks_nvim.lernbaum")

  local LUA = table.concat({
    "",
    "Warum: Neovim-Plugins schreiben.",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lua lernen {#lua}",
    "  - [ ] Syntax erlernen {#syntax}",
    "    - [x] [Lua 5.4 Reference Manual, Kap. 3](https://www.lua.org/manual/5.4/)",
    "      > Notiz: Operatorrangfolge von `..` und `^` merken.",
    "    - [~] [Programming in Lua, Kap. 1–5](https://www.lua.org/pil/) – Grund: nur Kap. 1 gebraucht, Rest Wiederholung",
    "    - [ ] ![Syntaxdiagramm](assets/images/lua-syntax.svg)",
    "  - [ ] C-Compiler erlernen → learning/c-compiler {#cc}",
    "  - [-] Lua-JIT-Interna – Grund: für das Ziel nicht nötig",
    "",
    "## Notizen",
    "",
    "- [ ] not a learning point: another section",
    "",
  }, "\n")

  local t = lb.parse(LUA)
  eq(t.has_section, true)
  eq(#t.roots, 1)
  eq(#t.nodes, 7, "the checkbox under ## Notizen is no node")
  local lua = t.roots[1]
  eq(lua.key, "lua")
  eq(lua.label, "Lua lernen")
  eq(#lua.children, 3)
  local syntax = t.by_key.syntax
  eq(syntax.depth, 1)
  eq(syntax.parent, lua)
  eq(#syntax.children, 3)

  local manual = syntax.children[1]
  eq(manual.state, "learned")
  eq(manual.link, "https://www.lua.org/manual/5.4/")
  eq(manual.note, "Notiz: Operatorrangfolge von `..` und `^` merken.")
  local pil = syntax.children[2]
  eq(pil.state, "seen")
  eq(pil.reason, "nur Kap. 1 gebraucht, Rest Wiederholung")
  eq(pil.label, "[Programming in Lua, Kap. 1–5](https://www.lua.org/pil/)")
  eq(syntax.children[3].image, "assets/images/lua-syntax.svg")
  eq(syntax.children[3].link, nil, "an image is no link")

  local cc = t.by_key.cc
  eq(cc.promoted, "learning/c-compiler")
  eq(cc.label, "C-Compiler erlernen")
  local jit = lua.children[3]
  eq(jit.state, "dropped")
  eq(jit.reason, "für das Ziel nicht nötig")
  eq(jit.label, "Lua-JIT-Interna")

  -- the parent rule and the progress, counted apart
  eq(syntax.derived, "partial")
  eq(syntax.closed, false, "one leaf of Syntax is open")
  eq(syntax.progress, { learned = 1, seen = 1, dropped = 0, open = 1, blocked = 0, total = 3 })
  eq(t.progress, { learned = 1, seen = 1, dropped = 1, open = 2, blocked = 0, total = 5 })
  eq(lb.progress_text(t.progress), "1 gelernt · 1 angeschaut · 1 entfällt · 2 offen")
  eq(t.problems, {})
  eq(lb.promoted_ids(t), { "learning/c-compiler" })

  -- render gives the text back byte for byte; with CRLF, too
  eq(lb.render(t), LUA)
  local crlf = LUA:gsub("\n", "\r\n")
  local tc = lb.parse(crlf)
  eq(#tc.nodes, 7)
  eq(tc.by_key.syntax.label, "Syntax erlernen", "the CR is not part of the line")
  eq(lb.render(tc), crlf)

  -- set_state: a leaf changes, the line is written anew, nothing else moves
  ok(lb.set_state(t, "#9", "learned") == nil, "no node 9")
  local node, err = lb.set_state(t, 5, "learned")
  eq(err, nil)
  eq(node.state, "learned")
  local after = lb.render(t)
  eq(
    after,
    (LUA:gsub("    %- %[ %] !%[Syntaxdiagramm%]", "    - [x] ![Syntaxdiagramm]", 1)),
    "only the line of the leaf changed"
  )
  eq(t.by_key.syntax.closed, true)
  eq(t.by_key.syntax.derived, "partial", "one leaf only seen")
  local _, perr = lb.set_state(t, "syntax", "learned")
  ok(perr and perr:find("children"), "a parent has no mark of its own")
  local _, rerr = lb.set_state(t, "cc", "dropped")
  ok(rerr and rerr:find("reason"), "dropped needs a reason")
  lb.set_state(t, "cc", "dropped", "kommt später")
  eq(
    lb.render(t):match("[^\n]*C%-Compiler[^\n]*"),
    "  - [-] C-Compiler erlernen → learning/c-compiler – Grund: kommt später {#cc}"
  )
  eq(lb.parse(lb.render(t)).by_key.cc.reason, "kommt später", "what render writes parse reads")
  lb.set_state(t, "cc", "open")
  eq(t.by_key.cc.reason, nil, "an open point has no reason")

  -- all leaves learned: the parent is learned
  local all = lb.parse("## Lernpunkte\n- [ ] A\n  - [x] a1\n  - [X] a2\n")
  eq(all.roots[1].derived, "learned")
  eq(all.roots[1].closed, true)
  eq(all.roots[1].mark, " ", "the parent's own mark is not read")

  -- blocked counts as open and once more as blocked; an English heading and the arrow -> are read, too
  local en =
    lb.parse("## Learning points\n\n- [!] Zugang LiveCompare -> learning/zugang\n- [x] B\n")
  eq(en.has_section, true)
  eq(en.nodes[1].state, "blocked")
  eq(en.nodes[1].promoted, "learning/zugang")
  eq(en.progress.open, 1)
  eq(en.progress.blocked, 1)

  -- `->` before a word that is no id is text, no arrow; `→` before one is a bad arrow
  local text_arrow = lb.parse("## Lernpunkte\n- [ ] Lua -> C lernen\n- [ ] Map a -> b\n")
  eq(text_arrow.problems, {})
  eq(text_arrow.nodes[1].label, "Lua -> C lernen")
  eq(text_arrow.nodes[2].promoted, nil)

  -- the problems one file can tell: no reason, a key twice, a bad key, an unknown mark, an arrow to no id, an image
  -- outside assets/
  local bad = lb.parse(table.concat({
    "## Lernpunkte",
    "- [~] angeschaut ohne Grund {#a}",
    "- [-] entfällt ohne Grund",
    "- [ ] zweimal {#a}",
    "- [ ] Großbuchstaben {#Key}",
    "- [?] unbekannt",
    "- [ ] Pfeil → nirgendwo",
    "- [ ] ![x](../secret.svg)",
  }, "\n"))
  local codes = {}
  for _, p in ipairs(bad.problems) do
    codes[#codes + 1] = p.code .. "@" .. p.line
  end
  table.sort(codes)
  eq(codes, {
    "path-bad-arrow@7",
    "path-bad-key@5",
    "path-bad-mark@6",
    "path-duplicate-key@4",
    "path-image-outside@8",
    "path-reason-missing@2",
    "path-reason-missing@3",
  })

  -- a checkbox in a code block is text; a body without the section has no tree
  local fenced =
    lb.parse("## Lernpunkte\n\n```markdown\n- [ ] Beispiel\n## Lernpunkte\n```\n- [ ] echt\n")
  eq(#fenced.nodes, 1)
  eq(fenced.nodes[1].label, "echt")
  local none = lb.parse("Prose.\n\n## Plan\n\n- [ ] 1. Schritt\n")
  eq(none.has_section, false)
  eq(#none.nodes, 0)
  eq(lb.render(none), "Prose.\n\n## Plan\n\n- [ ] 1. Schritt\n")
  eq(lb.parse("").has_section, false)

  -- set_note: a note is written, changed and removed; every other line stays byte for byte
  local NOTE = table.concat({
    "## Lernpunkte",
    "",
    "- [ ] Lua lernen {#lua}",
    "  - [x] Handbuch {#manual}",
    "    > alt eins",
    "",
    "    > alt zwei",
    "  - [ ] Syntax {#syntax}",
    "",
    "Prosa danach.",
  }, "\n")
  local tn = lb.parse(NOTE)
  ok(lb.set_note(tn, "nope", "x") == nil, "no such point")
  local n1, nerr = lb.set_note(tn, "syntax", "Erste Zeile\n\nZweite Zeile")
  eq(nerr, nil)
  eq(n1.note, "Erste Zeile\n\nZweite Zeile")
  eq(
    lb.render(tn),
    NOTE:gsub(
      "  %- %[ %] Syntax {#syntax}",
      "  - [ ] Syntax {#syntax}\n    > Erste Zeile\n    >\n    > Zweite Zeile",
      1
    ),
    "a new note below the point, two columns deeper"
  )
  -- the note of another point (with a blank line inside) is replaced as a whole; the lines after it move
  local n2 = lb.set_note(tn, "manual", "neu ![Bild](assets/images/a.svg)")
  eq(n2.note, "neu ![Bild](assets/images/a.svg)")
  eq(n2.image, "assets/images/a.svg", "an image in the note is the image of the point")
  eq(
    tn.by_key.syntax.line,
    6,
    "the tree is parsed anew: three lines of the old note gave way to one"
  )
  eq(tn.by_key.syntax.note, "Erste Zeile\n\nZweite Zeile")
  ok(lb.render(tn):find("    > neu ![Bild](assets/images/a.svg)\n  - [ ] Syntax", 1, true))
  -- removed: an empty text (or only white space)
  lb.set_note(tn, "manual", "  \n")
  lb.set_note(tn, "syntax", "")
  eq(
    lb.render(tn),
    table.concat({
      "## Lernpunkte",
      "",
      "- [ ] Lua lernen {#lua}",
      "  - [x] Handbuch {#manual}",
      "  - [ ] Syntax {#syntax}",
      "",
      "Prosa danach.",
    }, "\n")
  )
  eq(tn.by_key.manual.note, nil)
  -- control characters are refused (a tab is text); CRLF in the text becomes one line break
  local _, cerr = lb.set_note(tn, "syntax", "a\0b")
  ok(cerr and cerr:find("control"), "a control character is refused")
  ok(lb.set_note(tn, "syntax", "a\tb"), "a tab is text")
  lb.set_note(tn, "syntax", "a\r\nb")
  eq(tn.by_key.syntax.note, "a\nb")
  -- a file with CRLF keeps it on the note lines; a state changed before stays
  local tcr = lb.parse((NOTE:gsub("\n", "\r\n")))
  lb.set_state(tcr, "syntax", "learned")
  lb.set_note(tcr, "syntax", "eins")
  ok(
    lb.render(tcr):find("  - [x] Syntax {#syntax}\r\n    > eins\r\n\r\nProsa", 1, true),
    lb.render(tcr)
  )
  eq(tcr.by_key.syntax.state, "learned")
end
