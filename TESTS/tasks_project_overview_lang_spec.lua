-- TESTS/tasks_project_overview_lang_spec.lua -- the generated overview block of a project (`projects --of --write`)
-- speaks the language of its document, else the vault's marker file, else German.

return function(H)
  local eq, has, lacks = H.eq, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local projects = require("tasks_nvim.projects")

  local root = F.vault(H)
  H.write(
    root .. "/ALL/ROADMAP/projects/netz.md",
    F.text({ { "title", "Netz" }, { "status", "doing" } })
  )
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(vim.deepcopy(argv), common), {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local function block(extra)
    return (extra or "")
      .. "<!-- GENERATED:plan scope=netz overview=ALL/netz start -->\n<!-- GENERATED:plan end -->\n"
  end
  local write = { "projects", "--of=ALL/netz", "--write=" }

  -- the words of the language of the document
  eq(projects.lang_of("Das ist das Ziel und die Abgrenzung."), "de")
  eq(projects.lang_of("The goal and the scope of the work."), "en")
  eq(projects.lang_of("Fußball"), "de", "an umlaut counts")
  eq(projects.lang_of("Rust"), nil)
  eq(
    projects.lang_of(
      "<!-- GENERATED:plan scope=x start -->\nthe and the\n<!-- GENERATED:plan end -->\n"
    ),
    nil,
    "generated text does not count"
  )

  -- a German document gets German words, an English one English words
  local de = root .. "/de.md"
  H.write(de, block("# Netz\n\nDas Ziel und die Abgrenzung des Projekts.\n\n"))
  local res = run({ write[1], write[2], write[3] .. de })
  eq(res.code, 0, res.err)
  local text = H.read(de)
  has(text, "Noch keine Pläne und keine Lernpfade.")
  has(text, "Eigene Tasks des Projekts: 0 offen.")
  lacks(text, "No plans and no learning paths yet.")

  local en = root .. "/en.md"
  H.write(en, block("# Net\n\nThe goal and the scope of the project.\n\n"))
  res = run({ write[1], write[2], write[3] .. en })
  eq(res.code, 0, res.err)
  text = H.read(en)
  has(text, "No plans and no learning paths yet.")
  has(text, "Own tasks of the project: 0 open.")
  lacks(text, "Noch keine Pläne")

  -- an old English block in a German document: --check names it stale once, --write rewrites it, then it is current
  H.write(
    de,
    "# Netz\n\nDas Ziel und die Abgrenzung des Projekts.\n\n"
      .. "<!-- GENERATED:plan scope=netz overview=ALL/netz start -->\n**Netz** (doing)\n\n"
      .. "No plans and no learning paths yet.\n\nOwn tasks of the project: 0 open.\n"
      .. "<!-- GENERATED:plan end -->\n"
  )
  res = run({ write[1], write[2], write[3] .. de, "--check" })
  eq(res.code, 1, "the English block is stale")
  has(res.out, "stale")
  res = run({ write[1], write[2], write[3] .. de })
  has(res.out, "written")
  eq(run({ write[1], write[2], write[3] .. de, "--check" }).code, 0, "current after the rewrite")

  -- the refresh after a finish keeps the language of the document
  local refreshed = assert(require("tasks_nvim.plan_scope").refresh_document(de, root))
  eq(refreshed.changed, false)

  -- a document that says neither: the vault's marker file, else German
  local none = root .. "/none.md"
  H.write(none, block("# Netz\n\n"))
  run({ write[1], write[2], write[3] .. none })
  has(H.read(none), "Noch keine Pläne und keine Lernpfade.")
  H.write(root .. "/tasks-vault.json", require("tasks_nvim.vault_marker").render({ lang = "en" }))
  H.write(none, block("# Netz\n\n"))
  run({ write[1], write[2], write[3] .. none })
  has(H.read(none), "No plans and no learning paths yet.")
end
