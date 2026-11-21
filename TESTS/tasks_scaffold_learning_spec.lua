-- TESTS/tasks_scaffold_learning_spec.lua -- the category `learning`: its four scaffold lines (de, en), the template
-- `learning` of `plans.new` for a plan (sections and the proposed stages) and a learning path (the sections of the
-- concept's §5 around `## Lernpunkte`), and `plan-new --template=learning` on the command line.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local lernbaum = require("tasks_nvim.lernbaum")
  local model = require("tasks_nvim.model")
  local paths = require("tasks_nvim.paths")
  local plans = require("tasks_nvim.plans")

  local TODAY = "2026-11-19"

  -- ── the scaffold lines ────────────────────────────────────────────────────
  local de = model.scaffold({ kind = "task", category = { "learning" } }, "de")
  local ids = vim.tbl_map(function(r)
    return r.id
  end, de)
  for _, id in ipairs({ "learn-sources", "learn-result", "learn-selfcheck", "learn-questions" }) do
    ok(vim.tbl_contains(ids, id), id .. " is a line of learning: " .. vim.inspect(ids))
  end
  has(de[#de].text, "Offene Fragen notiert")
  local en = model.scaffold({ category = { "learning" } }, "en")
  eq(#en, 4)
  eq(en[3].text, "Self-check answered without notes")

  -- ── a learning plan ───────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = TODAY }
  local made = assert(plans.new(
    "lib.nvim",
    vim.tbl_extend("force", o, {
      title = "LiveCompare lernen",
      template = "learning",
    })
  ))
  local text = H.read(made.path)
  has(text, "phase_order: [orientieren, grundlagen, vertiefen, anwenden, festigen]\n")
  has(text, "## Ziel und Kompetenzstufe\n")
  has(text, "## Definition of done\n")
  lacks(text, "## Lernpunkte", "the tree belongs to the path, not the plan")

  local own = assert(plans.new(
    "lib.nvim",
    vim.tbl_extend("force", o, {
      title = "Eigene Stufen",
      template = "learning",
      phases = "lesen,machen",
    })
  ))
  has(H.read(own.path), "phase_order: [lesen, machen]\n", "stages given win over the proposal")

  local _, bad =
    plans.new("lib.nvim", vim.tbl_extend("force", o, { title = "X", template = "cooking" }))
  has(bad, "unknown template 'cooking'")

  local plain =
    assert(plans.new("lib.nvim", vim.tbl_extend("force", o, { title = "Ohne Vorlage" })))
  local ptext = H.read(plain.path)
  has(ptext, "## Ziel und Abgrenzung\n", "without a template a plan is what it was")
  lacks(ptext, "phase_order")

  -- ── a learning path ───────────────────────────────────────────────────────
  local path = assert(paths.new(
    "lib.nvim",
    vim.tbl_extend("force", o, {
      title = "Lua lernen",
      template = "learning",
    })
  ))
  local ltext = H.read(path.path)
  lacks(ltext, "phase_order", "a path has no stages, also with the learning template")
  for _, heading in ipairs({
    "## Ziel und Kompetenzstufe",
    "## Zugang",
    "## Zeitplan",
    "## Quellen",
    "## Lernpunkte",
    "## Level",
    "## Selbstcheck",
    "## Offene Fragen",
    "## Wiederholung",
    "## Ergebnis schreiben",
  }) do
    has(ltext, "\n" .. heading .. "\n", heading)
  end
  -- the rules of a learning path (LP-07, LP-06, LP-11, LP-15, LP-18)
  has(
    ltext,
    "| Quelle | Typ | Worauf achten | Zugang | Geprüft |",
    "the date a source was checked"
  )
  has(ltext, "„ungeprüft“")
  for _, stage in ipairs(plans.LEARNING_PHASES) do
    has(ltext, "{#" .. stage .. "}", "the stage " .. stage .. " is named in the hint")
  end
  has(ltext, "{#literatur}", "the group of the literature")
  has(ltext, "Fehlt im Bestand")
  has(ltext, "Terminologie, DocLinks, Portfolio-Notiz, Support-Scope")
  ok(
    ltext:find("## Lernpunkte", 1, true) < ltext:find("## Level", 1, true)
      and ltext:find("## Wiederholung", 1, true) < ltext:find("## Ergebnis schreiben", 1, true)
      and ltext:find("## Ergebnis schreiben", 1, true) < ltext:find("## Notizen", 1, true),
    "the order of the model paths"
  )
  local found = assert(paths.find(path.id, { root = root }))
  ok(found.tree.has_section, "the tree reads the section")
  eq(#found.tree.nodes, 0, "and finds no points yet (the hints are comments)")
  eq(#found.errors, 0, vim.inspect(found.errors))
  ok(found.levels and found.levels.has_section, "the level section is there")
  eq(#found.levels.levels, 0, "its example is a comment: no level yet")
  eq(found.levels.final, nil)
  eq(found.levels.problems, {}, "and no problem")
  local report =
    assert(require("tasks_nvim.check").run({ root = root, area = "lib.nvim", today = TODAY }))
  for _, f in ipairs(report.findings) do
    ok(f.id ~= path.id, "check has nothing to say about a new learning path: " .. vim.inspect(f))
  end
  ok(lernbaum.parse(ltext:match("\n%-%-%-\n(.*)$") or "").has_section)

  -- ── the command line ──────────────────────────────────────────────────────
  local out, err = {}, {}
  local code = cli.run({
    "plan-new",
    "lib.nvim",
    "Rust lernen",
    "--template=learning",
    "--vault=" .. root,
    "--today=" .. TODAY,
  }, {
    out = function(t)
      out[#out + 1] = t
    end,
    err = function(t)
      err[#err + 1] = t
    end,
  })
  eq(code, 0, table.concat(err))
  local rust = assert(plans.find("lib.nvim/rust-lernen", { root = root }))
  has(H.read(rust.path), "phase_order: [orientieren, grundlagen, vertiefen, anwenden, festigen]")
end
