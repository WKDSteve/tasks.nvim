-- TESTS/tasks_exercise_spec.lua -- the exercise block under a learning point (`> **Aufgabe:**` ...): the parts read
-- from a note, which points count as exercises, a point with a `Nachweis` that is learned only with a result
-- (`LP-04`), the `Ergebnis` written byte for byte beside the other parts, a point without a block that ticks as before,
-- `paths.point` writing the result and the tick in one call, and the `path-exercise-vague` hint of `check`.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local ex = require("tasks_nvim.exercise")
  local lb = require("tasks_nvim.lernbaum")

  -- ── reading the parts of a note ──
  local note = table.concat({
    "**Aufgabe:** Lege drei Dateien an",
    "und zeige sie mit `ls -l` an.",
    "**Fertig, wenn:** du je Option einen Satz sagen kannst.",
    "**Nachweis:** Ausgabe von `ls -lh` einfügen.",
    "**Ergebnis:**",
  }, "\n")
  local parts = ex.parse(note)
  eq(
    parts.aufgabe,
    "Lege drei Dateien an und zeige sie mit `ls -l` an.",
    "a part runs over several lines"
  )
  eq(
    parts.fertig,
    "du je Option einen Satz sagen kannst.",
    "the label may hold a comma and a space"
  )
  eq(parts.nachweis, "Ausgabe von `ls -lh` einfügen.")
  eq(parts.ergebnis, "", "a label with no text is present and empty")
  eq(ex.parse(nil), {})
  eq(ex.parse("Notiz: nur Fließtext"), {}, "text before a label is no part")
  eq(ex.parse("**Anderes:** x\n**Aufgabe:** y"), { aufgabe = "y" }, "an unknown label is no part")
  eq(ex.has_block(note), true)
  eq(ex.has_block("Notiz: Fließtext"), false)

  -- ── which points are exercises, which are vague ──
  for _, label in ipairs({
    "Üben: ls",
    "Ueben: ls",
    "Übung: x",
    "Aufgabe: y",
    "Mini-Projekt backup.sh",
    "Projekt: z",
  }) do
    ok(ex.is_exercise(label), label)
  end
  for _, label in ipairs({ "Werkzeuge: ls", "Tag 1: Navigation", "Fehlerquellen bewusst auslösen" }) do
    ok(not ex.is_exercise(label), label)
  end
  ok(ex.is_vague("Üben: ls", nil), "an exercise without a note is vague")
  ok(ex.is_vague("Üben: ls", "**Aufgabe:**"), "an empty Aufgabe is vague")
  ok(not ex.is_vague("Üben: ls", note))
  ok(not ex.is_vague("Werkzeuge: ls", nil), "a reading point is not an exercise")

  -- ── needs_result: a Nachweis without a Ergebnis ──
  ok(ex.needs_result(note))
  ok(not ex.needs_result(note:gsub("%*%*Ergebnis:%*%*", "**Ergebnis:** drwxr-xr-x ...")))
  ok(not ex.needs_result("**Aufgabe:** nur die Aufgabe"), "no Nachweis: nothing to prove")
  ok(not ex.needs_result(nil))

  -- ── with_result: set where it stands, added when missing, other lines kept ──
  local set = assert(ex.with_result(note, "drwxr-xr-x  3 u g 96 ."))
  eq(ex.parse(set).ergebnis, "drwxr-xr-x  3 u g 96 .")
  eq(ex.parse(set).aufgabe, parts.aufgabe, "the other parts are as they were")
  local added = assert(ex.with_result("**Aufgabe:** a\n**Nachweis:** n", "fertig"))
  eq(
    added,
    "**Aufgabe:** a\n**Nachweis:** n\n**Ergebnis:** fertig",
    "a block without the line gets it"
  )
  local multi = assert(ex.with_result(note, "zwei\nZeilen"))
  eq(ex.parse(multi).ergebnis, "zwei Zeilen")
  local none, nerr = ex.with_result("Notiz: Fließtext", "x")
  eq(none, nil)
  has(nerr, "no exercise block")
  local _, cerr = ex.with_result(note, "a\1b")
  has(cerr, "control characters")

  -- ── the tree: learned needs the result, the other marks do not ──
  local TEXT = table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [ ] Stufe 1 {#s1}",
    "  - [ ] Üben: Verzeichnis anzeigen {xp=10} {#u1}",
    "    > **Aufgabe:** Lege drei Dateien an und zeige sie mit `ls -l`.",
    "    > **Fertig, wenn:** du je Option einen Satz sagen kannst.",
    "    > **Nachweis:** Ausgabe von `ls -lh` einfügen.",
    "    > **Ergebnis:**",
    "  - [ ] Üben: Pfad prüfen {xp=10} {#u2}",
    "  - [ ] Werkzeuge: ls lesen {xp=5} {#w}",
    "",
  }, "\n")
  local t = lb.parse(TEXT)
  eq(#t.problems, 0, vim.inspect(t.problems))
  local u1 = t.by_key.u1
  ok(ex.needs_result(u1.note), "the note of the point is the block")
  local refused, err = lb.set_state(t, "u1", "learned")
  eq(refused, nil)
  has(err, "needs a result")
  eq(t.by_key.u1.state, "open", "a refused tick changes nothing")
  assert(lb.set_state(t, "u1", "seen", "nur gelesen"), "seen with a reason is allowed")
  assert(lb.set_state(t, "u1", "open"))
  assert(lb.set_result(t, "u1", "drwxr-xr-x 3 u g 96 ."))
  has(lb.render(t), "    > **Ergebnis:** drwxr-xr-x 3 u g 96 .")
  assert(lb.set_state(t, "u1", "learned"), "learned with a result")
  eq(t.by_key.u1.state, "learned")
  local back = lb.render(t)
  has(back, "    > **Aufgabe:** Lege drei Dateien an und zeige sie mit `ls -l`.")
  has(back, "  - [x] Üben: Verzeichnis anzeigen {xp=10} {#u1}")
  assert(lb.set_state(t, "u2", "learned"), "a point without a block ticks as before")
  assert(lb.set_state(t, "w", "learned"), "a reading point too")
  local _, rerr = lb.set_result(t, "w", "x")
  has(rerr, "no exercise block")

  -- ── on disk: paths.point writes the result and the tick in one call, check hints at vague points ──
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local paths = require("tasks_nvim.paths")
  local root = F.vault(H)
  local o = { root = root, today = "2026-11-23", checkpoint_dir = H.tmpdir() .. "/cp" }
  local A = "lib.nvim"
  local file = root .. "/" .. A .. "/ROADMAP/paths/cli-uebung/cli-uebung.md"
  H.write(
    file,
    table.concat({
      "---",
      "title: CLI Übung",
      "status: doing",
      "updated: 2026-11-23",
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [ ] Stufe 1 {#s1}",
      "  - [ ] Üben: Verzeichnis anzeigen {xp=10} {#u1}",
      "    > **Aufgabe:** Lege drei Dateien an.",
      "    > **Fertig, wenn:** du es erklären kannst.",
      "    > **Nachweis:** Ausgabe einfügen.",
      "    > **Ergebnis:**",
      "  - [ ] Üben: Pfad prüfen {xp=10} {#u2}",
      "",
    }, "\n")
  )
  local id = A .. "/cli-uebung"
  local _, terr, tinfo = paths.point(id, "u1", "learned", nil, o)
  eq(tinfo.code, "invalid_argument")
  has(terr, "needs a result")
  has(H.read(file), "  - [ ] Üben: Verzeichnis anzeigen", "the refused tick wrote nothing")
  local res = assert(
    paths.point(id, "u1", "learned", nil, vim.tbl_extend("force", o, { result = "ls -lh: ok" }))
  )
  eq(res.node.state, "learned")
  local disk = H.read(file)
  has(disk, "  - [x] Üben: Verzeichnis anzeigen {xp=10} {#u1}")
  has(disk, "    > **Ergebnis:** ls -lh: ok")
  local _, werr, winfo =
    paths.point(id, "u2", nil, nil, vim.tbl_extend("force", o, { result = "x" }))
  eq(winfo.code, "invalid_argument")
  has(werr, "no exercise block")
  local _, nerr2 = paths.point(id, "u2", nil, nil, o)
  has(nerr2, "give a state, a note, a result or xp")

  local checked = assert(check.run({ root = root, area = A }))
  local hint
  for _, h in ipairs(checked.hints) do
    if h.code == "path-exercise-vague" and h.id == id then
      hint = h
    end
  end
  ok(hint, "u2 has no task text")
  eq(hint.severity, "info")
  has(hint.message, "1 exercise point(s) without a task text")
  for _, f in ipairs(checked.findings) do
    ok(f.code ~= "path-exercise-vague", "a hint, never a finding")
  end
end
