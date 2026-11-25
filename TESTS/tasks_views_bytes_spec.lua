-- TESTS/tasks_views_bytes_spec.lua -- the bytes of a saved view in the vault: the text a view is written as, and what a
-- change of it leaves. The texts below are what the files had before the shape of a view moved to
-- `lib.nvim.view_file`; they must not change, the files are the user's.

return function(H)
  local eq = H.eq
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local views = require("tasks_nvim.views")

  local root = F.vault(H)

  local FULL = "---\ntitle: Everything\ndisplay: matrix\ngroup_by: status\ngroup_by2: prio\n"
    .. "collapsed: [open, done]\nsel_areas: [lib.nvim, cascade.nvim]\nsel_statuses: [open]\nsel_actors: [cdx]\n"
    .. "sel_kinds: [bug]\nsel_tags: [x, y]\nsel_plans: [lib.nvim/p]\nsel_projects: [proj]\nsel_query: pin it\n"
    .. "created: 2026-01-01\nupdated: 2026-01-01\n---\n\n"
  local PATCHED =
    "---\ntitle: Everything\ndisplay: list\ngroup_by: status\ncreated: 2026-01-01\nupdated: 2026-02-02\n---\n\n"
  local MINIMAL =
    "---\ntitle: Plain\ndisplay: columns\ngroup_by: actor\ncreated: 2026-03-03\nupdated: 2026-03-03\n---\n\n"

  local full = {
    title = "Everything",
    display = "matrix",
    group_by = "status",
    group_by2 = "prio",
    collapsed = { "open", "done" },
    select = {
      areas = { "lib.nvim", "cascade.nvim" },
      statuses = { "open" },
      actors = { "cdx" },
      kinds = { "bug" },
      tags = { "x", "y" },
      plans = { "lib.nvim/p" },
      projects = { "proj" },
      query = "pin it",
    },
  }
  local made = assert(views.save(root, "lib.nvim", full, { today = "2026-01-01" }))
  eq(made.id, "lib.nvim/everything")
  eq(H.read(made.path), FULL, "tasks views: a new view file")

  local listed = views.all(root)
  eq(listed[1].select.tags[2], "y", "tasks views: the file reads back")

  local mini = { title = "Everything", display = "list", group_by = "status" }
  assert(
    views.save(
      root,
      "lib.nvim",
      mini,
      { slug = made.slug, if_match = made.etag_after, today = "2026-02-02" }
    )
  )
  eq(H.read(made.path), PATCHED, "tasks views: a changed view file loses what is no longer set")

  local plain = assert(
    views.save(
      root,
      "lib.nvim",
      { title = "Plain", display = "columns", group_by = "actor" },
      { today = "2026-03-03" }
    )
  )
  eq(H.read(plain.path), MINIMAL, "tasks views: a minimal view file")
end
