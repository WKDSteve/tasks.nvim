-- TESTS/tasks_paths_spec.lua -- learning paths (`ROADMAP/paths/`): reading the file and its tree, new / set / point /
-- close (the Backlog, `closed_kind: path`, the folder form), the one id namespace, the `check` findings of a path
-- (tree problems, a dangling arrow, a missing image, a cycle over the `## Lernpunkte` of tasks), and a task without the
-- new parts as before.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- @scans-data: the spec lists only its own fixture vault in the temp folder
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local paths = require("tasks_nvim.paths")
  local plans = require("tasks_nvim.plans")
  local projects = require("tasks_nvim.projects")
  local check = require("tasks_nvim.check")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  local opts = { root = root, today = "2026-11-19" }
  local A = "lib.nvim"

  ---@return table<string, string[]> code -> ids
  local function codes_of(result)
    local out = {}
    for _, f in ipairs(result.findings) do
      out[f.code] = out[f.code] or {}
      table.insert(out[f.code], f.id or f.path)
    end
    return out
  end

  -- ── a path file is made with the tree section, read back, and has no stages ──
  local made, err = paths.new(A, vim.tbl_extend("force", opts, { title = "Lua lernen" }))
  eq(err, nil)
  eq(made.id, A .. "/lua-lernen")
  eq(made.path, vault.path_path(root, A, "lua-lernen"))
  local text = H.read(made.path)
  ok(text:find("\n## Lernpunkte\n", 1, true), "the new file has the tree section")
  ok(not text:find("phase_order", 1, true), "a path has no stages")
  local p = assert(paths.find(made.id, opts))
  ok(p.valid, table.concat(p.errors, "; "))
  eq(p.kind, "path")
  eq(p.status, "planning")
  eq(p.tree.has_section, true)
  eq(#p.tree.nodes, 0, "the template's hint is a comment, no node")

  local _, serr = paths.new(A, vim.tbl_extend("force", opts, { title = "X", phases = "a,b" }))
  ok(serr and serr:find("no stages"), "phases refused")
  local _, gerr = paths.new(A, vim.tbl_extend("force", opts, { title = "X", gate = "hard" }))
  ok(gerr and gerr:find("no stages"), "gate refused")

  -- the tree of the concept, written by hand into the file
  local body = table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lua lernen {#lua}",
    "  - [ ] Syntax erlernen {#syntax}",
    "    - [x] [Manual](https://www.lua.org/manual/5.4/)",
    "    - [ ] Kapitel 2 {#k2}",
    "  - [ ] C-Compiler erlernen → lib.nvim/c-compiler {#cc}",
    "",
    "## Notizen",
    "",
  }, "\n")
  local head = text:match("^(%-%-%-\n.-\n%-%-%-\n)")
  H.write(made.path, head .. body)
  p = assert(paths.find(made.id, opts))
  eq(#p.tree.nodes, 5)
  eq(p.tree.progress.learned, 1)
  eq(p.tree.progress.open, 2)

  -- ── point: one leaf changes on disk, every other byte stays ──
  local before = H.read(made.path)
  local res, perr = paths.point(made.id, "k2", "seen", "nur überflogen", opts)
  eq(perr, nil)
  eq(res.changed, true)
  eq(res.node.state, "seen")
  eq(res.progress.seen, 1)
  local after = H.read(made.path)
  eq(
    after,
    before:gsub(
      "    %- %[ %] Kapitel 2 {#k2}",
      "    - [~] Kapitel 2 – Grund: nur überflogen {#k2}",
      1
    ),
    "only the line of the point changed (updated was today already)"
  )
  local _, cerr, cinfo = paths.point(
    made.id,
    "k2",
    "learned",
    nil,
    vim.tbl_extend("force", opts, {
      if_match = "sha256:0000000000000000",
    })
  )
  eq(cinfo and cinfo.code, "conflict", cerr)
  local _, xerr, xinfo = paths.point(made.id, "syntax", "learned", nil, opts)
  eq(xinfo and xinfo.code, "invalid_argument", xerr)
  local _, nerr, ninfo = paths.point(A .. "/nope", "k2", "learned", nil, opts)
  eq(ninfo and ninfo.code, "not_found", nerr)

  -- a path file with no body at all: no such point, not "cannot place the body"
  local bare = assert(paths.new(A, vim.tbl_extend("force", opts, { title = "Leer" })))
  H.write(bare.path, "---\ntitle: Leer\nstatus: planning\n---\n")
  local _, berr, binfo = paths.point(bare.id, "k", "learned", nil, opts)
  eq(binfo and binfo.code, "invalid_argument")
  ok(berr and berr:find("no such learning point", 1, true), berr)
  os.remove(bare.path)

  -- ── set: the keys of a path; stages are none of them ──
  local sres, sset =
    paths.set(made.id, { status = "doing", links = { "https://www.lua.org" } }, opts)
  eq(sset, nil)
  eq(sres.changed, true)
  eq(assert(paths.find(made.id, opts)).status, "doing")
  local _, pset = paths.set(made.id, { phase_order = { "a" } }, opts)
  ok(pset and pset:find("unknown field"), "phase_order is no key of a path")
  local _, dset = paths.set(made.id, { status = "done" }, opts)
  ok(dset and dset:find("close"), "a path is finished with close")

  -- a path in a project: allowed, without a stage; the project must exist
  local proj = assert(projects.find and plans.new(
    A,
    vim.tbl_extend("force", opts, {
      title = "Neovim können",
      kind = "project",
    })
  ))
  local _, prerr = paths.set(made.id, { project = A .. "/nichts" }, opts)
  ok(prerr and prerr:find("no such open project"), prerr)
  assert(paths.set(made.id, { project = proj.id }, opts))
  eq(assert(paths.find(made.id, opts)).project, proj.id)

  -- ── a stage in the file is a fault of the file ──
  local staged = plans.parse("---\ntitle: T\nstatus: planning\nphase_order: [a]\n---\n", {
    path = root .. "/" .. A .. "/ROADMAP/paths/t.md",
    area = A,
    kind = "path",
  })
  ok(not staged.valid)
  ok(vim.tbl_contains(staged.error_codes, "path-no-stages"))
  local bad_status = plans.parse("---\ntitle: T\nstatus: wip\n---\n", {
    path = root .. "/" .. A .. "/ROADMAP/paths/t.md",
    area = A,
    kind = "path",
  })
  ok(vim.tbl_contains(bad_status.error_codes, "path-bad-status"), "plan- codes read path-")

  -- ── one id namespace: a task cannot take the slug of a path, nor a path a task's ──
  local t = assert(mutate.new(A, { title = "Lua lernen", root = root, today = opts.today }))
  ok(t.id ~= made.id, "the new task got another slug than the path: " .. t.id)
  F.task(H, root, A, "c-compiler", F.meta("C-Compiler", "open"), "\nDer Compiler.\n")
  local again = assert(paths.new(A, vim.tbl_extend("force", opts, { title = "C-Compiler" })))
  eq(again.id, A .. "/c-compiler-2")
  ok(again.renamed)
  os.remove(again.path)

  -- ── check: a sound path has no findings; then the tree problems, a dangling arrow, a missing image, a cycle ──
  local clean = codes_of(assert(check.run(opts)))
  for code in pairs(clean) do
    ok(code:sub(1, 5) ~= "path-", "no path finding on a sound vault: " .. code)
  end

  local broken = paths.new(A, vim.tbl_extend("force", opts, { title = "Kaputt" }))
  local bhead = H.read(broken.path):match("^(%-%-%-\n.-\n%-%-%-\n)")
  H.write(broken.path, bhead .. table.concat({
    "",
    "## Lernpunkte",
    "",
    "- [~] ohne Grund {#a}",
    "- [ ] zweimal {#a}",
    "- [ ] Pfeil ins Leere → lib.nvim/gibt-es-nicht",
    "- [ ] ![Bild](assets/fehlt.svg)",
    "- [ ] je Punkt ein Test rot → grün",
    "- [ ] Siehe → lib.nvim/Fast_Eine_Id",
    "",
  }, "\n"))
  local run = assert(check.run(opts))
  local found = codes_of(run)
  eq(found["path-reason-missing"], { broken.id })
  eq(found["path-duplicate-key"], { broken.id })
  eq(found["path-arrow-dangling"], { broken.id })
  eq(found["path-image-missing"], { broken.id })
  -- an arrow in the text is no finding; one before a word that looks like an id is a hint, never a warning
  eq(found["path-bad-arrow"], nil)
  local arrow_hints = {}
  for _, h in ipairs(run.hints) do
    if h.code == "path-bad-arrow" then
      arrow_hints[#arrow_hints + 1] = h.id .. " " .. h.message:match("^line %d+")
    end
  end
  eq(arrow_hints, { broken.id .. " line 9" })
  os.remove(broken.path)

  -- a cycle: the path names c-compiler, c-compiler's points name back the path (through a second task)
  F.task(
    H,
    root,
    A,
    "c-compiler",
    F.meta("C-Compiler", "open"),
    "\nDer Compiler.\n\n## Lernpunkte\n\n- [ ] Sprache C → lib.nvim/sprache-c\n"
  )
  F.task(
    H,
    root,
    A,
    "sprache-c",
    F.meta("Sprache C", "open"),
    "\nC.\n\n## Lernpunkte\n\n- [ ] Zurück → lib.nvim/c-compiler\n"
  )
  local cyc = assert(check.run(opts))
  local ring
  for _, f in ipairs(cyc.findings) do
    if f.code == "path-cycle" then
      ring = f.message
    end
  end
  ok(
    ring and ring:find("lib.nvim/c-compiler -> lib.nvim/sprache-c -> lib.nvim/c-compiler", 1, true),
    ring
  )
  eq(codes_of(cyc)["path-cycle"], { made.id }, "reported once, on the path")
  F.task(H, root, A, "sprache-c", F.meta("Sprache C", "open"), "\nC.\n")

  -- an id another file of the area has: an open task of the same slug, written by hand
  F.task(H, root, A, "lua-lernen", F.meta("Doppelt", "open"))
  ok(codes_of(assert(check.run(opts)))["path-id-taken"], "the slug of a task is taken")
  os.remove(root .. "/" .. A .. "/ROADMAP/tasks/lua-lernen.md")

  -- ── attach turns a path into its folder form; close moves it with its assets ──
  local src = H.tmpdir() .. "/shot.svg"
  H.write(src, "<svg xmlns='http://www.w3.org/2000/svg'/>")
  local att, aerr = mutate.attach(made.id, src, { root = root, kind = "image" })
  ok(att, aerr)
  p = assert(paths.find(made.id, opts))
  eq(p.folder, true)
  eq(p.path, vault.plan_folder_path(root, "path", A, "lua-lernen"))

  local closed, clerr = paths.close(made.id, vim.tbl_extend("force", opts, { date = "2026-11-19" }))
  eq(clerr, nil)
  local stem = "2026-11-19_lua-lernen"
  eq(closed.to, vault.backlog_dir(root, A, "FEATURES") .. "/" .. stem .. "/" .. stem .. ".md")
  ok(vim.uv.fs_stat(closed.to), "the finished path is in the Backlog")
  ok(H.read(closed.to):find("\nclosed_kind: path\n", 1, true))
  eq(paths.find(made.id, opts), nil, "no open path any more")
  local done = assert(scan.find_done(made.id, { root = root }))
  eq(projects.finished_kind(done), "path")
  ok(H.read(vault.backlog_readme(root, A)):find(stem, 1, true), "a row in the README")

  -- a finished path of a project is no finished task of the project
  local roll = projects.rollup(assert(projects.find(proj.id, opts)), {
    plans = {},
    open = {},
    root = root,
  })
  eq(roll.tasks_done, 0)

  -- ── a task without the new parts reads as before: no tree on the task ──
  local plain = assert(scan.find(t.id, { root = root }))
  eq(plain.tree, nil)
end
