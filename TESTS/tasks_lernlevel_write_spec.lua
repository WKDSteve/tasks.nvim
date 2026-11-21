-- TESTS/tasks_lernlevel_write_spec.lua -- the `## Level` section written from a spec (`lernlevel.render`, `write`,
-- `spec_of`): what it renders reads back the same, other text of the section and of the body stays byte for byte,
-- CRLF is kept, an empty spec removes the section, a spec that cannot be written is refused with its reason; and the
-- operation `path_levels` of tasks-ops/1 (inverse, dry run, if_match, not_found).
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local ll = require("tasks_nvim.lernlevel")
  local M = "\194\183"

  local SPEC = {
    list = {
      {
        threshold = 20,
        unit = "xp",
        name = "Einsteiger",
        badge = "assets/badges/stern.png",
        reward = "Eis",
        given = true,
      },
      { threshold = 50, unit = "percent", reward = "Kino" },
      { threshold = 80, unit = "xp", name = "Profi", given = true },
    },
    done = { reward = "Wochenende am See" },
  }

  -- ── render: one line per level, the path line last; given only with a reward ──
  local lines = assert(ll.render(SPEC))
  eq(lines, {
    "- [x] 20 XP "
      .. M
      .. " Einsteiger "
      .. M
      .. " Badge assets/badges/stern.png "
      .. M
      .. " Belohnung: Eis",
    "- [ ] 50 % " .. M .. " Belohnung: Kino",
    "- [ ] 80 XP " .. M .. " Profi",
    "- [ ] Pfad fertig " .. M .. " Belohnung: Wochenende am See",
  })

  -- ── write into a body without the section: added at the end, and it reads back as the spec ──
  local BODY = "\n## Lernpunkte\n\n- [ ] a {xp=20}\n"
  local out = assert(ll.write(BODY, SPEC))
  eq(out, BODY .. "\n## Level\n\n" .. table.concat(lines, "\n") .. "\n")
  local back = ll.parse(out)
  eq(#back.problems, 0, vim.inspect(back.problems))
  local spec = ll.spec_of(back)
  eq(spec.list[1], SPEC.list[1])
  eq(spec.list[2], { threshold = 50, unit = "percent", reward = "Kino" })
  eq(
    spec.list[3],
    { threshold = 80, unit = "xp", name = "Profi" },
    "given without a reward is dropped"
  )
  eq(spec.done, { reward = "Wochenende am See" })
  -- the same spec again changes nothing
  eq(assert(ll.write(out, spec)), out)

  -- ── a section with other text and a next section: the level lines are replaced in place ──
  local WITH = table.concat({
    "## Level",
    "",
    "Was ich mir gönne:",
    "",
    "- [ ] 10 XP " .. M .. " Belohnung: alt",
    "- [x] Pfad fertig " .. M .. " Belohnung: alt",
    "",
    "Danach weiter.",
    "",
    "## Notizen",
    "",
    "- [ ] keine Stufe",
    "",
  }, "\n")
  local w = assert(ll.write(WITH, { list = { { threshold = 5, unit = "xp", name = "Neu" } } }))
  eq(
    w,
    table.concat({
      "## Level",
      "",
      "Was ich mir gönne:",
      "",
      "- [ ] 5 XP " .. M .. " Neu",
      "",
      "Danach weiter.",
      "",
      "## Notizen",
      "",
      "- [ ] keine Stufe",
      "",
    }, "\n")
  )
  -- empty: the level lines go, the text of the section stays
  local e = assert(ll.write(WITH, { list = {} }))
  has(e, "Was ich mir gönne:")
  eq(ll.parse(e).levels, {})
  eq(ll.parse(e).final, nil)

  -- ── empty spec on a section of only levels: the whole section goes, the rest stays ──
  eq(assert(ll.write(out, { list = {} })), BODY)
  local MID = "## A\n\ntext\n\n## Level\n\n- [ ] 5 XP\n\n## B\n\nmore\n"
  eq(assert(ll.write(MID, { list = {} })), "## A\n\ntext\n\n## B\n\nmore\n")
  -- and nothing to remove: the body as it is
  eq(assert(ll.write(BODY, { list = {} })), BODY)

  -- ── a heading of its own (`## Stufen`) without lines, followed by a section: filled, a blank line kept ──
  eq(
    assert(ll.write("## Stufen\n\n## B\n", { list = { { threshold = 5, unit = "xp" } } })),
    "## Stufen\n\n- [ ] 5 XP\n\n## B\n"
  )

  -- ── CRLF stays CRLF ──
  local crlf = assert(ll.write(H.crlf(WITH), { list = { { threshold = 5, unit = "xp" } } }))
  ok(not crlf:find("[^\r]\n"), "every line ends with CRLF")
  has(crlf, "- [ ] 5 XP\r\n")

  -- ── refused: the reason names the field ──
  local function refused(s, needle)
    local res, err = ll.write(BODY, s)
    eq(res, nil)
    has(tostring(err), needle)
  end
  refused(
    { list = { { threshold = 0, unit = "xp" } } },
    "threshold must be a whole number from 1 to"
  )
  refused({ list = { { threshold = 101, unit = "percent" } } }, "from 1 to 100")
  refused({ list = { { threshold = 5, unit = "pts" } } }, "unit must be xp or percent")
  refused({
    list = { { threshold = 50, unit = "xp" }, { threshold = 50, unit = "xp" } },
  }, "threshold must rise")
  refused({ list = { { threshold = 5, unit = "xp", name = "a " .. M .. " b" } } }, "part the line")
  refused({ list = { { threshold = 5, unit = "xp", name = "a | b" } } }, "part the line")
  refused({ list = { { threshold = 5, unit = "xp", name = "Badge x" } } }, "badge or a reward")
  refused({ list = { { threshold = 5, unit = "xp", reward = "a\nb" } } }, "control character")
  refused({ list = { { threshold = 5, unit = "xp", name = ("x"):rep(81) } } }, "longer than 80")
  refused(
    { list = { { threshold = 5, unit = "xp", badge = "assets/badges/../x.png" } } },
    "below assets/badges/"
  )
  refused(
    { list = { { threshold = 5, unit = "xp", badge = "assets/x.png" } } },
    "below assets/badges/"
  )
  refused({ list = { { threshold = 5, unit = "xp", badge = "assets/badges/x.exe" } } }, "png, jpg")
  refused(
    { list = { { threshold = 5, unit = "xp", badge = "assets/badges/a b.png" } } },
    "no blanks"
  )
  refused({ list = { { threshold = 5, unit = "xp", colour = "red" } } }, "unknown field 'colour'")
  refused({ list = {}, extra = 1 }, "unknown field 'extra'")
  refused({ list = "x" }, "levels.list must be a list")
  refused({ list = {}, done = { given = "yes" } }, "given must be true or false")
  local many = {}
  for i = 1, ll.MAX_LEVELS + 1 do
    many[i] = { threshold = i, unit = "xp" }
  end
  refused({ list = many }, "more than 20 levels")
  -- a section with lines a spec cannot hold has no spec (its inverse would lose them)
  eq(ll.spec_of(ll.parse("## Level\n\n- [ ] viel · Eis\n")), nil)

  -- ── the operation `path_levels` ──
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local ops = require("tasks_nvim.ops")
  local fsio = require("tasks_nvim.fsio")
  local TODAY = "2026-11-21"
  local root = F.vault(H)
  local file = root .. "/lib.nvim/ROADMAP/paths/lv.md"
  local TEXT = "---\ntitle: Lv\nstatus: doing\nupdated: 2026-11-01\n---\n\n## Lernpunkte\n\n- [ ] a {xp=20}\n"
    .. "\n## Level\n\n- [x] 10 XP "
    .. M
    .. " Belohnung: Eis\n"
  H.write(file, TEXT)
  local function one(op, dry)
    local doc, err = ops.run({ ops = { op }, dry_run = dry }, { root = root, today = TODAY })
    eq(doc and doc.kind, "tasks.result", vim.inspect(err))
    return doc.results[1]
  end
  local ID = "lib.nvim/lv"
  local NEW =
    { list = { { threshold = 15, unit = "xp", name = "Neu" } }, done = { reward = "Kino" } }
  local d = one({ op = "path_levels", id = ID, levels = NEW }, true)
  eq({ d.ok, d.outcome }, { true, "would_change" })
  eq(H.read(file), TEXT, "a dry run writes nothing")
  local r = one({ op = "path_levels", id = ID, levels = NEW })
  eq({ r.ok, r.outcome, r.changed_ids }, { true, "changed", { ID } })
  has(H.read(file), "- [ ] 15 XP " .. M .. " Neu\n- [ ] Pfad fertig " .. M .. " Belohnung: Kino\n")
  has(H.read(file), "updated: " .. TODAY)
  eq(r.inverse.op, "path_levels")
  eq(r.inverse.levels.list[1], { threshold = 10, unit = "xp", reward = "Eis", given = true })
  eq(r.inverse.levels.done, nil)
  eq(r.inverse.if_match, fsio.etag(H.read(file)))
  -- the inverse brings the levels back
  local inv = one(r.inverse)
  eq(inv.outcome, "changed")
  eq(H.read(file):gsub("updated: [%d-]+", ""), TEXT:gsub("updated: [%d-]+", ""))
  -- the same again: unchanged
  eq(one({ op = "path_levels", id = ID, levels = r.inverse.levels }).outcome, "unchanged")
  -- refusals
  local bad =
    one({ op = "path_levels", id = ID, levels = { list = { { threshold = 0, unit = "xp" } } } })
  eq({ bad.ok, bad.error.code }, { false, "invalid_argument" })
  local stale = one({ op = "path_levels", id = ID, levels = NEW, if_match = "old" })
  eq(stale.error.code, "conflict")
  eq(one({ op = "path_levels", id = "lib.nvim/nope", levels = NEW }).error.code, "not_found")
  eq(one({ op = "path_levels", id = ID }).error.code, "invalid_argument")
  -- a line separator, a C1 character or broken UTF-8 in a text of the levels: refused as everywhere else
  for _, text in ipairs({ "a\226\128\168b", "a\194\155b", "a\255b" }) do
    local c = one({
      op = "path_levels",
      id = ID,
      levels = {
        list = { { threshold = 5, unit = "xp", reward = text } },
        done = { reward = "ok" },
      },
    })
    eq({ c.ok, c.error.code }, { false, "invalid_argument" }, vim.inspect(text))
    has(c.error.message, "control character")
    local d2 =
      one({ op = "path_levels", id = ID, levels = { list = {}, done = { reward = text } } })
    eq(d2.error.code, "invalid_argument")
  end

  -- ── the words of the lines: the section's own, else the vault's language, else German ──
  local EN_BODY = "\n## Level\n\n- [ ] 10 XP " .. M .. " Reward: ice cream\n- [ ] Path done\n"
  eq(ll.lang_of(EN_BODY), "en")
  eq(ll.lang_of("\n## Level\n\n- [ ] 10 XP " .. M .. " Belohnung: Eis\n"), "de")
  eq(ll.lang_of("\n## Level\n\n- [ ] 10 XP\n"), nil, "no word: no language")
  eq(ll.lang_of("\n## Lernpunkte\n\n- [ ] Reward: x\n"), nil, "outside the section nothing counts")
  local en_out = assert(ll.write(EN_BODY, NEW))
  has(en_out, "- [ ] 15 XP " .. M .. " Neu\n- [ ] Path done " .. M .. " Reward: Kino\n")
  ok(not en_out:find("Belohnung", 1, true), "an English section stays English")
  -- the section's own words win over the vault's
  has(assert(ll.write(EN_BODY, NEW, { lang = "de" })), "Path done")
  -- a new section: the vault's language, else German; an unknown one is German
  has(
    assert(ll.write("\n## Lernpunkte\n", NEW, { lang = "en" })),
    "- [ ] Path done " .. M .. " Reward: Kino"
  )
  has(assert(ll.write("\n## Lernpunkte\n", NEW)), "Pfad fertig " .. M .. " Belohnung: Kino")
  has(assert(ll.write("\n## Lernpunkte\n", NEW, { lang = "fr" })), "Pfad fertig")
  -- and what it writes in English reads back the same
  local spec_en = ll.spec_of(ll.parse(en_out))
  eq(spec_en.done, { reward = "Kino" })

  -- through the write door in an English vault: the marker file names the language
  local root_en = F.vault(H)
  H.write(
    root_en .. "/tasks-vault.json",
    require("tasks_nvim.vault_marker").render({ lang = "en" })
  )
  local file_en = root_en .. "/lib.nvim/ROADMAP/paths/lv-en.md"
  H.write(
    file_en,
    "---\ntitle: Lv en\nstatus: doing\nupdated: 2026-11-01\n---\n\n## Lernpunkte\n\n- [ ] a {xp=20}\n"
  )
  local doc_en = ops.run(
    { ops = { { op = "path_levels", id = "lib.nvim/lv-en", levels = NEW } } },
    { root = root_en, today = TODAY }
  )
  eq(doc_en.results[1].ok, true, vim.inspect(doc_en.results[1]))
  has(H.read(file_en), "- [ ] Path done " .. M .. " Reward: Kino\n")
end
