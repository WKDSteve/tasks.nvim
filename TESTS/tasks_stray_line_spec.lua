-- TESTS/tasks_stray_line_spec.lua -- `path-stray-line`: a line of `## Lernpunkte` that is no point, no note below one
-- and not empty is lost to the tree (a link label broken across two lines); `check` names it with its line and the
-- marks on it, in a learning path and in a task's own tree. Comments, sub-headings, code blocks and the paragraph
-- `Fehlt im Bestand: …` (LP-11) are text on purpose.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- @scans-data: the spec lists only its own fixture vault in the temp folder

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local lernbaum = require("tasks_nvim.lernbaum")
  local check = require("tasks_nvim.check")
  local paths = require("tasks_nvim.paths")
  local mutate = require("tasks_nvim.mutate")

  ---@param body string
  ---@return string[] "<line>:<text>|<marks>"
  local function strays(body)
    local out = {}
    for _, s in ipairs(lernbaum.parse(body).stray) do
      out[#out + 1] = ("%d:%s|%s"):format(s.line, s.text, table.concat(s.marks, " "))
    end
    return out
  end

  -- ── the tree: what is a stray line ──────────────────────────────────────
  local broken = table.concat({
    "## Lernpunkte", -- 1
    "", -- 2
    "- [ ] [GO: Kap. 8–9, Goroutines und", -- 3
    "Nebenläufigkeit](https://x.org) {xp=15} {#w10-lesen}", -- 4: the lost half
    "- [ ] Zweiter Punkt {xp=5}", -- 5
    "  > eine Notiz unter dem Punkt", -- 6
    "loser Satz", -- 7
    "", -- 8
    "## Notizen", -- 9
    "freier Text", -- 10: another section, no finding
  }, "\n")
  eq(strays(broken), {
    "4:Nebenläufigkeit](https://x.org) {xp=15} {#w10-lesen}|{xp=15} {#w10-lesen}",
    "7:loser Satz|",
  })
  local tree = lernbaum.parse(broken)
  eq(#tree.nodes, 2, "the stray line is no point")
  eq(tree.by_key["w10-lesen"], nil, "its key counts for nothing")

  local clean = table.concat({
    "## Lernpunkte",
    "",
    "<!-- ein Kommentar -->",
    "<!-- einer",
    "über zwei Zeilen -->",
    "### Zwischenüberschrift",
    "- [ ] Punkt {#a}",
    "  - [x] Unterpunkt",
    "    > Notiz",
    "    > weiter",
    "```",
    "Code im Baum",
    "```",
    "- [ ] Hintergrund aus der Literatur {#literatur}",
    "",
    "Fehlt im Bestand: ein Buch zu Svelte 5; die offizielle",
    "Doku reicht.",
    "",
    "## Level",
    "",
  }, "\n")
  eq(
    strays(clean),
    {},
    "comments, sub-headings, notes, code and the shelf paragraph are no stray lines"
  )
  eq(
    strays("## Lernpunkte\n\n> eine Notiz ohne Punkt\n"),
    { "3:> eine Notiz ohne Punkt|" },
    "a quote below no point is stray"
  )
  eq(
    strays("## Lernpunkte\n\nFehlt im Bestand: x\n\nnoch ein Satz\n"),
    { "5:noch ein Satz|" },
    "the shelf paragraph ends at its blank line"
  )
  eq(strays("## Notizen\n\nText\n"), {}, "no section, no stray line")

  -- ── check: a path and a task ────────────────────────────────────────────
  local root = F.vault(H)
  local opts = { root = root, today = F.TODAY }
  local A = "lib.nvim"
  ---@param file string
  ---@return string[]
  local function stray_findings(file)
    local out = {}
    for _, f in ipairs(check.run(opts).findings) do
      if f.path == file and f.code == "path-stray-line" then
        ok(f.severity == "warn", "a warning")
        out[#out + 1] = f.message
      end
    end
    return out
  end

  local p = assert(paths.new(A, vim.tbl_extend("force", opts, { title = "Lose Zeilen" })))
  eq(stray_findings(p.path), {}, "a fresh path has no stray line")
  local text = H.read(p.path)
  local lines = vim.split(text, "\n")
  local at
  for i, l in ipairs(lines) do
    if l == "## Lernpunkte" then
      at = i
    end
  end
  ok(at, "the path has ## Lernpunkte")
  table.insert(lines, at + 1, "- [ ] Erster Teil und")
  table.insert(lines, at + 2, "zweiter Teil {xp=15} {#w10}")
  H.write(p.path, table.concat(lines, "\n"))
  eq(stray_findings(p.path), {
    ("line %d: not a point, a note or empty, so the tree skips it: zweiter Teil {xp=15} {#w10} ({xp=15} {#w10} count for nothing here)"):format(
      at + 2
    ),
  }, "the file's line, the marks named")

  local t = assert(mutate.new(A, vim.tbl_extend("force", opts, { title = "Lernen mit Baum" })))
  H.write(t.path, H.read(t.path) .. "\n## Lernpunkte\n\n- [ ] Punkt\nlose Zeile\n")
  local hits = stray_findings(t.path)
  eq(#hits, 1, "a task's own tree")
  local n = #vim.split(H.read(t.path), "\n") - 1
  ok(hits[1]:find(("^line %d: .*: lose Zeile$"):format(n)), hits[1])
  H.write(t.path, (H.read(t.path):gsub("lose Zeile\n", "")))
  eq(stray_findings(t.path), {}, "gone with the line")

  -- a long stray line is quoted in part
  H.write(t.path, H.read(t.path) .. ("x"):rep(80) .. "\n")
  ok(stray_findings(t.path)[1]:find(("x"):rep(60) .. "…$"), "cut at 60 characters")
end
