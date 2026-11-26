-- TESTS/tasks_path_draft_spec.lua -- a learning path from a whole draft (`tasks path-new <area> --from=<draft.md>`,
-- `tasks_nvim.path_draft`): a sound draft is written as it is (the keys a path always has added), `--dry-run` writes
-- nothing, a draft with a fault is refused before anything is written and every finding names the draft's line and
-- its code, a hint does not refuse it, and the usage errors.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local check = require("tasks_nvim.check")
  local paths = require("tasks_nvim.paths")

  local TODAY = "2026-11-21"
  local root = F.vault(H)
  local A = "lib.nvim"
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

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

  ---@param name string
  ---@param lines string[]
  ---@return string path
  local function draft(name, lines)
    local p = dir .. "/" .. name
    H.write(p, table.concat(lines, "\n") .. "\n")
    return p
  end

  ---@param slug string
  ---@return string
  local function path_file(slug)
    return root .. "/" .. A .. "/ROADMAP/paths/" .. slug .. ".md"
  end

  -- an existing task the draft may name with an arrow, and a file its relative link may name
  F.task(H, root, A, "lua-tabellen", F.meta("Lua-Tabellen", "open"), "\nTabellen üben.\n")

  -- ── a sound draft: --dry-run names the path and writes nothing ──
  local sound_lines = {
    "---",
    "title: Lua lernen aus einem Entwurf",
    "areas: [lib.nvim]",
    "---",
    "",
    "Lua so weit lernen, dass sich ein Plugin lesen lässt.",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Grundlagen {#grundlagen}",
    "  - [ ] Typen und Werte {xp=5} {#typen}",
    "  - [ ] Tabellen → lib.nvim/lua-tabellen",
    "- [x] Lesen {xp=5} {#lesen} – [die Aufgabe](../tasks/lua-tabellen.md)",
    "",
    "## Notizen",
    "",
  }
  local sound = draft("sound.md", sound_lines)
  local _
  local code, out, err =
    run({ "path-new", A, "--from=" .. sound, "--slug=lua-entwurf", "--dry-run" })
  eq(code, 0, err)
  has(out, "would-create\t" .. A .. "/lua-entwurf\t")
  ok(H.read(path_file("lua-entwurf")) == nil, "a dry run writes nothing")

  -- ── the same draft written: its text as it was, the keys a path always has added at the end of the frontmatter ──
  code, out, err = run({ "path-new", A, "--from=" .. sound, "--slug=lua-entwurf" })
  eq(code, 0, err)
  has(out, "created\t" .. A .. "/lua-entwurf\t")
  local text = assert(H.read(path_file("lua-entwurf")), "the path is written: " .. err)
  has(text, "title: Lua lernen aus einem Entwurf\nareas: [lib.nvim]\nstatus: planning\n")
  has(text, "created: " .. TODAY .. "\n")
  has(text, "updated: " .. TODAY .. "\n")
  has(text, "- [ ] Tabellen → lib.nvim/lua-tabellen\n")
  local made = assert(paths.find(A .. "/lua-entwurf", { root = root }))
  eq(made.title, "Lua lernen aus einem Entwurf")
  eq(#made.tree.nodes, 4)
  -- and check finds nothing wrong with it
  for _, f in ipairs(assert(check.run({ root = root, area = A })).findings) do
    ok(
      f.id ~= A .. "/lua-entwurf",
      "no finding on the written draft: " .. f.code .. " " .. f.message
    )
  end
  -- the same draft again gets the next slug, as path-new gives it
  code, out, err = run({ "path-new", A, "--from=" .. sound, "--slug=lua-entwurf", "--dry-run" })
  eq(code, 0, err)
  has(out, "would-create\t" .. A .. "/lua-entwurf-2\t")
  has(err, "the slug was taken")

  -- ── a draft with faults: refused, nothing written, every finding with the draft's line and its code ──
  local broken = draft("broken.md", {
    "---", -- 1
    "title: Kaputter Entwurf", -- 2
    "---", -- 3
    "", -- 4
    "## Lernpunkte", -- 5
    "", -- 6
    "- [ ] eins {#a}", -- 7
    "- [ ] zwei {#a}", -- 8
    "- [q] drei {#c}", -- 9
    "- [ ] Pfeil ins Leere → lib.nvim/gibt-es-nicht", -- 10
    "- [ ] [tot](../tasks/fehlt.md) {#d}", -- 11
    "- [ ] {xp=viel} {#e}", -- 12
  })
  code, out, err = run({ "path-new", A, "--from=" .. broken })
  eq(code, 1, out)
  has(err, "warn\tpath-duplicate-key\tline 8: key {#a} is already on line 7")
  has(err, "warn\tpath-bad-mark\tline 9:")
  has(err, "warn\tpath-arrow-dangling\tline 10:")
  has(err, "warn\tpath-link-missing\tline 11:")
  has(err, "\tpath-bad-xp\tline 12:")
  has(err, "refused\t")
  lacks(out, "created")
  ok(H.read(path_file("kaputter-entwurf")) == nil, "a refused draft writes nothing")

  -- a link into a neighbour repo that is not checked out is a hint, not a fault: the draft is written
  local absent = "absent-" .. vim.fn.fnamemodify(root, ":t")
  local neighbour = draft("neighbour.md", {
    "---", -- 1
    "title: Mit Nachbar", -- 2
    "---", -- 3
    "", -- 4
    "## Lernpunkte", -- 5
    "", -- 6
    ("- [ ] [Buch](../../../../%s/buch.md) {#n}"):format(absent), -- 7
  })
  code, out, err = run({ "path-new", A, "--from=" .. neighbour, "--dry-run" })
  eq(code, 0, err)
  has(
    err,
    ("hint\tlink-repo-absent\tline 7: repo ../%s is not checked out: 1 link(s)"):format(absent)
  )
  lacks(err, "path-link-missing")
  has(out, "would-create\t")

  -- a fault of the frontmatter names the line of its key
  local staged = draft("staged.md", {
    "---",
    "title: Mit Etappen",
    "status: planning",
    "phase_order: [a, b]",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] eins {#a}",
  })
  code, _, err = run({ "path-new", A, "--from=" .. staged })
  eq(code, 1)
  has(err, "error\tpath-no-stages\tline 4:")
  ok(H.read(path_file("mit-etappen")) == nil)

  -- no frontmatter, no title: line 1
  code, _, err =
    run({ "path-new", A, "--from=" .. draft("bare.md", { "## Lernpunkte", "", "- [ ] x" }) })
  eq(code, 1)
  has(err, "error\tfrontmatter-missing\tline 1:")
  code, _, err = run({
    "path-new",
    A,
    "--from=" .. draft("untitled.md", { "---", "status: planning", "---", "" }),
  })
  eq(code, 1)
  has(err, "error\ttitle-missing\tline 1:")

  -- ── a hint does not refuse: a path with levels and a point without XP ──
  local hinted = draft("hinted.md", {
    "---",
    "title: Mit Level",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] mit XP {xp=10} {#a}",
    "- [ ] ohne XP {#b}",
    "",
    "## Level",
    "",
    "- [ ] 5 XP · Anfang",
    "",
  })
  code, out, err = run({ "path-new", A, "--from=" .. hinted })
  eq(code, 0, err)
  has(out, "created\t" .. A .. "/mit-level\t")
  -- the draft's line 8, though status, created and updated were added above the body
  has(err, "hint\txp-missing\tline 8:")

  -- ── the old note: a pipe in code splits a table row (hint `table-ragged`, the row's line, never a refusal) ──
  local note_lines = {
    "---",
    "title: Notiz mit Tabelle",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lesen {xp=10} {#lesen}",
    "",
    "## Notiz im Detail",
    "",
    "| Befehl | Zweck |",
    "| --- | --- |",
    "| `ls` | zeigt |",
    "| `ls -l | less` | zeigt seitenweise |",
    "| `ls -l \\| less` | escaped |",
    "| `a | b | c` | drei Pipes |",
    "",
    "| Name | Wert |",
    "|------|------|",
    "| x | y |",
    "",
    "```",
    "| a | b |",
    "|---|---|",
    "| 1 | 2 | 3 |",
    "```",
    "",
    "## Notizen",
    "",
    "| A | B |",
    "| --- | --- |",
    "| 1 | 2 | 3 |",
  }
  local note = draft("note.md", note_lines)
  code, _, err = run({ "path-new", A, "--from=" .. note, "--dry-run" })
  eq(code, 0, err)
  has(err, "hint\ttable-ragged\tline 14: table row has 3 cells, its header 2")
  has(err, "hint\ttable-ragged\tline 16: table row has 4 cells, its header 2")
  lacks(err, "table-ragged\tline 13", "a row of the right width")
  lacks(err, "table-ragged\tline 15", "an escaped pipe splits nothing")
  lacks(err, "table-ragged\tline 20", "the second table is sound")
  lacks(err, "table-ragged\tline 25", "inside a code fence")
  lacks(err, "table-ragged\tline 32", "only the section of the old note is read")
  local ragged = require("tasks_nvim.path_draft").ragged_rows(table.concat(note_lines, "\n"))
  eq(#ragged, 2)
  eq(ragged[1].severity, "info", "a hint, not a finding")
  code, _, err = run({ "path-new", A, "--from=" .. note })
  eq(code, 0, "a hint does not refuse the draft: " .. err)
  ok(H.read(path_file("notiz-mit-tabelle")) ~= nil, "written as it is")

  -- ── --dry-run without --from writes nothing either ──
  code, out, err = run({ "path-new", A, "Nur ein Probelauf", "--dry-run" })
  eq(code, 0, err)
  has(out, "would-create\t" .. A .. "/nur-ein-probelauf\t")
  ok(H.read(path_file("nur-ein-probelauf")) == nil, "a dry run of path-new writes nothing")

  -- ── usage ──
  code, _, err = run({ "path-new", A, "--from=" .. sound, "--areas=x" })
  eq(code, 2)
  has(err, "--areas goes into the draft's frontmatter")
  -- ── badges and images beside the draft: allowed and copied along, the path is written as a folder ──
  local bdir = dir .. "/mit-badges"
  vim.fn.mkdir(bdir .. "/assets/badges", "p")
  H.write(bdir .. "/assets/badges/stern.svg", "<svg/>")
  H.write(bdir .. "/assets/bild.png", "png")
  local badged = bdir .. "/entwurf.md"
  H.write(badged, table.concat({
    "---",
    "title: Mit Badges",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lesen ![Bild](assets/bild.png) {xp=10} {#lesen}",
    "",
    "## Level",
    "",
    "- [ ] 5 XP · Anfang · Badge assets/badges/stern.svg",
    "",
  }, "\n") .. "\n")
  local folder = root .. "/" .. A .. "/ROADMAP/paths/mit-badges"
  code, out, err = run({ "path-new", A, "--from=" .. badged, "--dry-run" })
  eq(code, 0, err)
  has(out, "would-copy\tassets/badges/stern.svg")
  has(out, "would-copy\tassets/bild.png")
  has(out, "would-create\t" .. A .. "/mit-badges\t")
  eq(vim.fn.isdirectory(folder), 0, "a dry run writes nothing")
  code, out, err = run({ "path-new", A, "--from=" .. badged })
  eq(code, 0, err)
  lacks(err, "level-badge-missing")
  lacks(err, "path-image-missing")
  has(out, "created\t" .. A .. "/mit-badges\t")
  eq(H.read(folder .. "/assets/badges/stern.svg"), "<svg/>")
  eq(H.read(folder .. "/assets/bild.png"), "png")
  ok(H.read(folder .. "/mit-badges.md"), "the folder form holds the path")
  eq(vim.fn.filereadable(path_file("mit-badges")), 0, "no plain file beside the folder")
  -- the written path is sound for `check` as well
  local res = assert(check.run({ root = root, area = A, today = TODAY }))
  for _, f in ipairs(res.findings) do
    ok(not (f.path or ""):find("mit-badges", 1, true), "check of the written path: " .. f.code)
  end

  -- a badge that is not beside the draft either is still refused, and nothing is copied
  vim.fn.delete(bdir .. "/assets/badges/stern.svg")
  H.write(badged, (H.read(badged):gsub("title: Mit Badges", "title: Ohne Stern")))
  code, out, err = run({ "path-new", A, "--from=" .. badged })
  eq(code, 1, out)
  has(err, "warn\tlevel-badge-missing\tline 11:")
  eq(vim.fn.isdirectory(root .. "/" .. A .. "/ROADMAP/paths/ohne-stern"), 0)
  -- a link that climbs out of the draft's folder is never looked up
  H.write(dir .. "/aussen.svg", "<svg/>")
  H.write(
    badged,
    (H.read(badged):gsub("assets/badges/stern.svg", "assets/badges/../../../aussen.svg"))
  )
  code, _, err = run({ "path-new", A, "--from=" .. badged })
  eq(code, 1)
  has(err, "level-badge")

  -- with assets the path lies one folder deeper: a relative link is judged from there, as `check` reads it later
  local ldir = dir .. "/mit-link"
  vim.fn.mkdir(ldir .. "/assets/badges", "p")
  H.write(ldir .. "/assets/badges/mond.svg", "<svg/>")
  local function linked_draft(title, link)
    local p = ldir .. "/entwurf.md"
    H.write(p, table.concat({
      "---",
      "title: " .. title,
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [ ] Lesen {xp=10} {#lesen} – [die Aufgabe](" .. link .. ")",
      "",
      "## Level",
      "",
      "- [ ] 5 XP · Anfang · Badge assets/badges/mond.svg",
      "",
    }, "\n") .. "\n")
    return p
  end
  -- right for a plain file, wrong for the folder the badge makes
  code, out, err =
    run({ "path-new", A, "--from=" .. linked_draft("Link flach", "../tasks/lua-tabellen.md") })
  eq(code, 1, out)
  has(err, "path-link-missing")
  eq(vim.fn.isdirectory(root .. "/" .. A .. "/ROADMAP/paths/link-flach"), 0)
  code, out, err =
    run({ "path-new", A, "--from=" .. linked_draft("Link tief", "../../tasks/lua-tabellen.md") })
  eq(code, 0, err)
  has(out, "created\t" .. A .. "/link-tief\t")
  res = assert(check.run({ root = root, area = A, today = TODAY }))
  for _, f in ipairs(res.findings) do
    ok(not (f.path or ""):find("link-tief", 1, true), "check of the written path: " .. f.code)
  end

  code, _, err = run({ "path-new", A, "Titel", "--from=" .. sound })
  eq(code, 2)
  has(err, "usage: path-new <area> --from=<draft.md>")
  code, _, err = run({ "path-new", A, "--from=" .. dir .. "/fehlt.md" })
  eq(code, 1)
  has(err, "cannot read")
  code, _, err = run({ "path-new", "keine-area", "--from=" .. sound })
  eq(code, 1)
  has(err, "unknown area")

  vim.fn.delete(dir, "rf")
end
