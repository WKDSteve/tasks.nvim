-- TESTS/tasks_path_schedule_spec.lua -- the schedule of a learning path made from its tree: `{h=…}` and `{done_h=…}` on
-- a point (`lernbaum`), the rows and the table (`path_schedule`), placed into `## Zeitplan`, and `tasks path
-- --schedule [--write]`.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local lb = require("tasks_nvim.lernbaum")
  local sched = require("tasks_nvim.path_schedule")
  local check = require("tasks_nvim.check")
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  -- ── the marks ──────────────────────────────────────────────────────────────
  eq({ lb.to_hours_span("8") }, { 8, 8 })
  eq({ lb.to_hours_span("8-10") }, { 8, 10 })
  eq({ lb.to_hours_span("1,5 \226\128\147 2") }, { 1.5, 2 })
  eq({ lb.to_hours_span("10-8") }, {}, "a span that falls")
  eq(lb.to_hours("1.25"), nil, "one decimal at most")
  eq(lb.to_hours("1001"), nil)
  eq(lb.to_hours("-1"), nil)

  local TREE = table.concat({
    "## Lernpunkte",
    "",
    "- [ ] Stufe 1 {#s1}",
    "  - [x] Woche 1: Prozesse {h=8-10} {done_h=9} {#w1}",
    "    - [x] Lesen {xp=5}",
    "    - [x] Aufgabe: `fork` | Experimente {xp=10}",
    "  - [ ] Woche 2: Threads {#w2} {h=6}",
    "    - [x] Lesen",
    "    - [ ] Nachweis: Producer/Consumer",
    "  - [ ] Woche 3 ohne Ergebnis {h=4}",
    "  - [ ] Ohne Dauer {#none}",
    "- [ ] Abschluss {h=2} {#end}",
    "  - [ ] Ergebnis:",
    "",
  }, "\n")
  local t = lb.parse(TREE)
  eq(t.problems, {})
  local w1 = t.by_key.w1
  eq(
    { w1.label, w1.h_min, w1.h_max, w1.done_h, w1.h_raw },
    { "Woche 1: Prozesse", 8, 10, 9, "8-10" }
  )
  eq({ t.by_key.w2.h_min, t.by_key.w2.label }, { 6, "Woche 2: Threads" })
  local bad = lb.parse("## Lernpunkte\n- [ ] A {h=viel} {#a}\n- [ ] B {done_h=2-3}\n")
  eq(#bad.problems, 2)
  eq({ bad.problems[1].code, bad.problems[1].key }, { "path-bad-hours", "a" })
  eq(bad.problems[2].code, "path-bad-hours")
  -- a change keeps them
  ok(lb.set_state(t, "w2", nil) == nil, "a parent has no state of its own")
  local t2 = lb.parse(TREE)
  ok(lb.set_state(t2, 6, "learned"))
  ok(lb.set_state(t2, "none", "learned"))
  has(lb.render(t2), "  - [x] Ohne Dauer {#none}\n")
  local t3 = lb.parse("## Lernpunkte\n- [ ] Woche {done_h=3} {h=2-4} {#w}\n")
  ok(lb.set_state(t3, "w", "learned"))
  eq(lb.render(t3), "## Lernpunkte\n- [x] Woche {h=2-4} {done_h=3} {#w}\n")

  -- ── the rows and the table ─────────────────────────────────────────────────
  local rows = sched.rows(t)
  eq(#rows, 4, "the points with hours, one level below a stage, and a root")
  eq({ rows[1].key, rows[1].state, rows[1].result }, { "w1", "done", "`fork` | Experimente" })
  eq({ rows[2].key, rows[2].state, rows[2].closed, rows[2].total, rows[2].result }, {
    "w2",
    "partial",
    1,
    2,
    "Producer/Consumer",
  })
  eq({ rows[3].state, rows[3].result }, { "open", nil })
  eq({ rows[4].key, rows[4].result }, { "end", nil }, "an empty result is none")
  eq(sched.render(rows), {
    "| Sitzung | Dauer | Ergebnis | Stand |",
    "| --- | --- | --- | --- |",
    "| Woche 1: Prozesse | 8\226\128\14710 h (gebraucht 9 h) | `fork` \\| Experimente | erledigt |",
    "| Woche 2: Threads | 6 h | Producer/Consumer | teilweise 1/2 |",
    "| Woche 3 ohne Ergebnis | 4 h | \226\128\147 | offen |",
    "| Abschluss | 2 h | \226\128\147 | offen |",
    "| Summe | 20\226\128\14722 h (gebraucht 9 h) | | 1/4 erledigt |",
  })
  eq(sched.render(sched.rows(lb.parse("## Lernpunkte\n- [ ] A\n"))), nil, "no hours, no schedule")

  -- ── placing it ─────────────────────────────────────────────────────────────
  local lines = { "| a |", "| --- |" }
  local hand =
    "## Zeitplan\n\n| Woche | Dauer |\n| --- | --- |\n| 1 | 8 h |\n\nText bleibt.\n\n## Quellen\n"
  local placed = assert(sched.place(hand, lines))
  eq(
    placed,
    "## Zeitplan\n\n"
      .. sched.START
      .. "\n| a |\n| --- |\n"
      .. sched.END
      .. "\n\nText bleibt.\n\n## Quellen\n",
    "the hand-kept table gives way"
  )
  eq(
    sched.place(placed, { "| b |" }),
    "## Zeitplan\n\n"
      .. sched.START
      .. "\n| b |\n"
      .. sched.END
      .. "\n\nText bleibt.\n\n## Quellen\n",
    "the second time between the markers"
  )
  eq(
    sched.place("## Zeitplan\nText\n", lines),
    "## Zeitplan\n\n" .. sched.START .. "\n| a |\n| --- |\n" .. sched.END .. "\n\nText\n"
  )
  eq(
    sched.place("## Zeitplan\r\n\r\n| x |\r\n", { "| a |" }),
    "## Zeitplan\r\n\r\n" .. sched.START .. "\r\n| a |\r\n" .. sched.END .. "\r\n",
    "CRLF stays"
  )
  local none, nerr = sched.place("## Quellen\n| x |\n", lines)
  eq(none, nil)
  has(nerr, "no section ## Zeitplan")
  local half, herr = sched.place("## Zeitplan\n" .. sched.START .. "\n| x |\n", lines)
  eq(half, nil)
  has(herr, "not a pair")
  -- a table in another section is not touched
  eq(
    sched.place("## Zeitplan\n\n## Quellen\n| q |\n", { "| a |" }),
    "## Zeitplan\n\n" .. sched.START .. "\n| a |\n" .. sched.END .. "\n\n## Quellen\n| q |\n"
  )

  -- ── the command line and check ─────────────────────────────────────────────
  local root = F.vault(H)
  local file = root .. "/lib.nvim/ROADMAP/paths/wochen.md"
  H.write(
    file,
    "---\ntitle: Wochen\nstatus: doing\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\n## Zeitplan\n\n"
      .. "| Woche | Dauer | Ergebnis |\n| --- | --- | --- |\n| Woche 1 | 8 h | alt |\n\n"
      .. TREE
  )
  local cli = require("tasks_nvim.cli")
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(argv, { "--vault=" .. root, "--today=" .. F.TODAY }), {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local before = H.read(file)
  local shown = run({ "path", "lib.nvim/wochen", "--schedule" })
  eq(shown.code, 0, shown.err)
  has(shown.out, "| Woche 2: Threads | 6 h | Producer/Consumer | teilweise 1/2 |\n")
  eq(H.read(file), before, "shown only")
  local wrote = run({ "path", "lib.nvim/wochen", "--schedule", "--write" })
  eq(wrote.code, 0, wrote.err)
  has(wrote.out, "schedule\tlib.nvim/wochen\t4 rows\twritten")
  local after = H.read(file)
  has(after, sched.START .. "\n| Sitzung | Dauer | Ergebnis | Stand |\n")
  ok(not after:find("| Woche 1 | 8 h | alt |", 1, true), "the hand-kept table is gone")
  has(after, "updated: " .. F.TODAY)
  eq(
    run({ "path", "lib.nvim/wochen", "--schedule", "--write" }).out:match("unchanged") ~= nil,
    true
  )
  eq(run({ "path", "lib.nvim/wochen", "--write" }).code, 2, "--write needs --schedule")
  -- a path without hours: nothing to write, and check says nothing about it
  H.write(
    root .. "/lib.nvim/ROADMAP/paths/ohne.md",
    "---\ntitle: Ohne\nstatus: doing\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\n## Zeitplan\n\n## Lernpunkte\n\n- [ ] A {#a}\n"
  )
  local no = run({ "path", "lib.nvim/ohne", "--schedule", "--write" })
  eq(no.code, 1)
  has(no.err, "no point carries {h=")
  local codes = {}
  for _, f in ipairs(check.run({ root = root, today = F.TODAY }).findings) do
    if f.path and f.path:find("ROADMAP/paths/", 1, true) then
      codes[f.code] = true
    end
  end
  eq(codes["path-bad-hours"], nil)
  eq(codes["path-schedule"], nil)
end
