-- TESTS/tasks_plan_links_assets_spec.lua -- plan and project files carry `links:` (http/https, checked as for a task)
-- and may become a folder (`plans/<slug>/<slug>.md`) whose other files are assets: `attach` and `folderize` take a plan
-- or project id, the engine finds and lists the folder form, the snapshot hands on links and assets, and finishing it
-- moves the folder with its assets to the Backlog.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local check = require("tasks_nvim.check")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local ops = require("tasks_nvim.ops")
  local plans = require("tasks_nvim.plans")
  local projects = require("tasks_nvim.projects")
  local scan = require("tasks_nvim.scan")
  local wikilinks = require("tasks_nvim.wikilinks")

  local root = F.vault(H)
  local GH = "https://github.com/example/repo/issues/7"
  local DOC = "https://example.org/docs#setup"

  ---@param list table[]
  ---@param attach? table
  ---@return table[] results
  local function run(list, attach)
    local doc, err = ops.run({ ops = list }, { root = root, today = F.TODAY, attach = attach })
    assert(doc, vim.inspect(err, { newline = " ", indent = "" }))
    return doc.results
  end

  -- ── links: written, read, refused ──
  local made = assert(plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Linked plan",
    web_links = { GH, DOC, GH },
  }))
  local plan = assert(plans.find(made.id, { root = root }))
  ok(plan.valid, table.concat(plan.errors, "; "))
  eq(plan.links, { GH, DOC }, "both addresses, once each, in order")
  eq(plan.folder, false)
  local _, lerr, linfo = plans.new(
    "lib.nvim",
    { root = root, today = F.TODAY, title = "Bad link", web_links = { "ftp://x.org/a" } }
  )
  has(lerr, "is not an http:// or https:// address")
  eq(linfo.code, "invalid_argument")

  local r = run({
    { op = "plan_new", area = "lib.nvim", title = "Door plan", links = { GH } },
    { op = "project_new", area = "lib.nvim", title = "Door project", links = { DOC } },
    { op = "plan_new", area = "lib.nvim", title = "Door bad", links = { "not a link" } },
  })
  eq(r[1].ok, true, vim.inspect(r[1]))
  eq(r[2].ok, true, vim.inspect(r[2]))
  eq(r[3].ok, false)
  eq(r[3].error.code, "invalid_argument")
  eq(assert(plans.find(r[1].id, { root = root })).links, { GH })
  local project_id = r[2].id
  eq(assert(projects.find(project_id, { root = root })).links, { DOC })

  -- plan_set / project_set change and remove them; a bad one is refused and nothing is written
  r = run({
    { op = "plan_set", id = made.id, patch = { links = { DOC } } },
    { op = "project_set", id = project_id, patch = { links = { "javascript:alert(1)" } } },
  })
  eq(r[1].ok, true, vim.inspect(r[1]))
  eq(assert(plans.find(made.id, { root = root })).links, { DOC })
  eq(r[2].ok, false)
  eq(r[2].error.code, "invalid_argument")
  eq(
    assert(projects.find(project_id, { root = root })).links,
    { DOC },
    "the refused change wrote nothing"
  )
  r = run({ { op = "plan_set", id = made.id, patch = { links = vim.NIL } } })
  eq(r[1].ok, true, vim.inspect(r[1]))
  eq(assert(plans.find(made.id, { root = root })).links, {})

  -- a hand-written entry that is no web address is the file's `bad-link`
  local broken = plans.parse(
    "---\ntitle: P\nstatus: doing\nlinks: [file:///etc/passwd]\n---\n\nGoal.\n",
    { path = root .. "/lib.nvim/ROADMAP/plans/p.md", area = "lib.nvim" }
  )
  ok(not broken.valid)
  eq(broken.error_codes, { "bad-link" })

  -- ── attach: a plan becomes its folder form ──
  local src = H.tmpdir() .. "/shot.png"
  H.write(src, "\137PNG\r\n\26\nimage")
  local att =
    assert(mutate.attach(made.id, src, { root = root, today = F.TODAY, kind = "screenshot" }))
  eq(att.folderized, true)
  eq(att.rel, "assets/screenshots/shot.png")
  eq(att.link, "![shot.png](assets/screenshots/shot.png)")
  local slug = made.slug
  local folder_file = root .. "/lib.nvim/ROADMAP/plans/" .. slug .. "/" .. slug .. ".md"
  eq(fsio.norm(att.path), fsio.norm(folder_file))
  ok(
    not fsio.is_file(root .. "/lib.nvim/ROADMAP/plans/" .. slug .. ".md"),
    "the plain file is gone"
  )
  plan = assert(plans.find(made.id, { root = root }))
  eq(plan.folder, true)
  ok(plan.valid, table.concat(plan.errors, "; "))
  eq(plans.assets(plan), { "assets/screenshots/shot.png" })
  local listed = false
  for _, p in ipairs(assert(plans.all({ root = root }))) do
    if p.id == made.id then
      listed = p.folder
    end
  end
  eq(listed, true, "plans.all lists the folder form")
  -- a bare [[slug]] link still names it, and the vault path of the folder form too
  local resolver = wikilinks.resolver(root)
  eq(wikilinks.typed_id("[[" .. slug .. "]]", "plan", resolver), made.id)
  eq(
    wikilinks.typed_id("[[lib.nvim/ROADMAP/plans/" .. slug .. "/" .. slug .. "]]", "plan", resolver),
    made.id
  )
  -- the slug stays taken: a new plan of that title gets another
  local again =
    assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Linked plan" }))
  ok(again.slug ~= slug, again.slug)

  -- the write door: an upload attached to a project; folderize of a plan that is one already changes nothing
  local inbox = H.tmpdir() .. "/uploads"
  H.write(inbox .. "/abc123", "%PDF-1.4 report")
  r = run({
    { op = "attach", id = project_id, from = "upload", upload = "abc123", name = "spec.pdf" },
  }, { upload_dir = inbox })
  eq(r[1].ok, true, vim.inspect(r[1]))
  eq(r[1].asset, "assets/spec.pdf")
  eq(r[1].link, "[spec.pdf](assets/spec.pdf)")
  local project = assert(projects.find(project_id, { root = root }))
  eq(project.folder, true)
  eq(plans.assets(project), { "assets/spec.pdf" })
  eq(assert(mutate.folderize(made.id, { root = root })).changed, false)
  local plain = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Folder me" }))
  local fz = assert(mutate.folderize(plain.id, { root = root }))
  eq(fz.changed, true)
  eq(assert(plans.find(plain.id, { root = root })).folder, true)
  -- an unknown id is still refused
  local _, nerr = mutate.attach("lib.nvim/no-such-thing", src, { root = root, today = F.TODAY })
  ok(nerr ~= nil)

  -- ── check: the folder form is no problem, an asset not an orphan ──
  local res = assert(check.run({ root = root }))
  for _, f in ipairs(res.findings) do
    ok(
      not tostring(f.id or ""):find(slug, 1, true)
        and not tostring(f.msg or ""):find("plans/", 1, true),
      vim.inspect(f)
    )
  end

  -- ── the snapshot hands on links, folder and assets ──
  run({ { op = "plan_set", id = made.id, patch = { links = { GH } } } })
  local snap = vim.json.decode((api.call("snapshot", "", { root = root, today = F.TODAY })))
  local entry, pentry
  for _, p in ipairs(snap.plans) do
    entry = p.id == made.id and p or entry
  end
  for _, p in ipairs(snap.projects) do
    pentry = p.id == project_id and p or pentry
  end
  eq(entry.links, { GH })
  eq(entry.folder, true)
  eq(entry.assets, { "assets/screenshots/shot.png" })
  eq(pentry.links, { DOC })
  eq(pentry.assets, { "assets/spec.pdf" })
  for _, p in ipairs(snap.plans) do
    if p.id == r[1].id then
      eq(p.folder, nil, "a plain file says nothing of a folder")
    end
  end

  -- ── finishing takes the folder with it ──
  local closed = assert(plans.close(made.id, { root = root, date = F.TODAY, today = F.TODAY }))
  local stem = F.TODAY .. "_" .. slug
  local done_dir = root .. "/lib.nvim/Backlog/FEATURES/" .. stem
  eq(fsio.norm(closed.to), fsio.norm(done_dir .. "/" .. stem .. ".md"))
  ok(fsio.is_file(done_dir .. "/assets/screenshots/shot.png"), "the asset went along")
  ok(not fsio.is_dir(root .. "/lib.nvim/ROADMAP/plans/" .. slug), "nothing is left behind")
  local finished = assert(scan.find_done(made.id, { root = root }))
  eq(finished.meta.status, "done")
  eq(finished.meta.closed_kind, "plan")
  has(H.read(root .. "/lib.nvim/Backlog/README.md"), stem .. "/" .. stem .. ".md")
  eq(plans.find(made.id, { root = root }), nil)
  -- a second close finds the finished one and changes nothing
  eq(assert(plans.close(made.id, { root = root, date = F.TODAY })).readme, "unchanged")

  -- a project in its folder form is finished the same way
  local pclosed =
    assert(projects.close(project_id, { root = root, date = F.TODAY, today = F.TODAY }))
  local pstem = F.TODAY .. "_" .. project_id:match("/(.+)$")
  has(pclosed.to, pstem .. "/" .. pstem .. ".md")
  ok(fsio.is_file(root .. "/lib.nvim/Backlog/FEATURES/" .. pstem .. "/assets/spec.pdf"))

  -- ── a plan that is a file AND a folder is an error, not a guess ──
  local twin = assert(plans.new("lib.nvim", { root = root, today = F.TODAY, title = "Twin" }))
  local tslug = twin.slug
  H.write(root .. "/lib.nvim/ROADMAP/plans/" .. tslug .. "/" .. tslug .. ".md", H.read(twin.path))
  local _, terr = plans.find(twin.id, { root = root })
  has(terr, "exists as file and as folder")
  local _, aerr = mutate.attach(twin.id, src, { root = root, today = F.TODAY })
  has(aerr, "exists as file and as folder")
end
