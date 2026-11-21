-- TESTS/tasks_relink_spec.lua -- relative links follow the file they name (`tasks_nvim.relink`): `done`, `reopen`,
-- `move_area` and `folderize` rewrite the links of other files (and the moved file's own) only where they would name
-- another file after the move, so `reopen` and `move_area` back give every text as it was; `relink.repair` (the CLI
-- `tasks relink`) mends the dead links a move left behind before, reports ambiguous ones and writes nothing on a dry run.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- @scans-data: the spec lists only its own fixture vault in the temp folder

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local relink = require("tasks_nvim.relink")
  local mdlinks = require("tasks_nvim.mdlinks")
  local mutate = require("tasks_nvim.mutate")
  local moves = require("tasks_nvim.moves")
  local cli = require("tasks_nvim.cli")

  -- ── the rule, on text ───────────────────────────────────────────────────
  eq(relink.relpath("/v/a/ROADMAP/tasks", "/v/a/Backlog/TASKS/x.md"), "../../Backlog/TASKS/x.md")
  eq(relink.relpath("/v/a/ROADMAP/tasks", "/v/a/ROADMAP/tasks/x.md"), "x.md")
  eq(relink.relpath("/v/a", "/v/b/c.md"), "../b/c.md")
  eq(relink.relpath("C:/v", "D:/v/x.md"), nil, "another drive has no relative path")
  ok(
    not mdlinks.is_relative("$REPOS_DIR/x.md") and not mdlinks.is_relative("~/x.md"),
    "a machine's path"
  )

  local mv = { { from = "/v/a/ROADMAP/tasks/x.md", to = "/v/a/Backlog/TASKS/2026-01-01_x.md" } }
  local text = table.concat({
    "[x](x.md) [anker](./x.md#teil) [spitz](<x.md>) [y](y.md) [web](https://x.org/x.md)",
    "`[c](x.md)` [x2](../tasks/x.md)",
  }, "\n")
  local out, edits = relink.rewrite(text, "/v/a/ROADMAP/tasks", "/v/a/ROADMAP/tasks", mv)
  eq(
    out,
    table.concat({
      "[x](../../Backlog/TASKS/2026-01-01_x.md) [anker](./../../Backlog/TASKS/2026-01-01_x.md#teil)"
        .. " [spitz](<../../Backlog/TASKS/2026-01-01_x.md>) [y](y.md) [web](https://x.org/x.md)",
      "`[c](x.md)` [x2](../../Backlog/TASKS/2026-01-01_x.md)",
    }, "\n"),
    "only the links to the moved file; anchors kept; code and web untouched"
  )
  eq(#edits, 4)
  local back = relink.rewrite(out, "/v/a/ROADMAP/tasks", "/v/a/ROADMAP/tasks", {
    { from = mv[1].to, to = mv[1].from },
  })
  eq(
    back,
    text:gsub("%.%./tasks/x%.md", "x.md"),
    "back again: the shortest form (only a detour is lost)"
  )
  eq(
    relink.rewrite(
      "[s](./sub/x.md)\r\n",
      "/v/d",
      "/v/d",
      { { from = "/v/d/sub", to = "/v/d/neu" } }
    ),
    "[s](./neu/x.md)\r\n",
    "a folder move; ./ and CRLF kept"
  )
  eq(
    select(2, relink.rewrite(text, "/v/a/ROADMAP/tasks", "/v/a/ROADMAP/tasks", {})),
    {},
    "no move, no edit"
  )

  -- ── done and reopen in a vault ──────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = F.TODAY }
  local A, B = "lib.nvim", "cascade.nvim"
  local function new(area, title, body)
    local made = assert(mutate.new(area, vim.tbl_extend("force", o, { title = title })))
    if body then
      H.write(made.path, H.read(made.path) .. body)
    end
    return made
  end
  local y = new(A, "Nachbar")
  local x = new(A, "Ziel", "\nSiehe [Nachbar](" .. y.slug .. ".md).\n")
  local w = new(A, "Andere")
  H.write(
    y.path,
    H.read(y.path)
      .. ("\n[Ziel](%s.md) [Teil](./%s.md#k) [Andere](%s.md)\n"):format(x.slug, x.slug, w.slug)
  )
  local z = new(B, "Fern", ("\n[Ziel](../../../%s/ROADMAP/tasks/%s.md)\n"):format(A, x.slug))
  local meeting = root .. "/" .. A .. "/MEETINGS/treffen.md"
  H.write(
    meeting,
    ("---\ntitle: Treffen\nstatus: planned\ndate: 2026-12-01\n---\n\n[Ziel](../ROADMAP/tasks/%s.md)\n"):format(
      x.slug
    )
  )
  -- a finished file links the task too: the Backlog is history, `done` does not read it (`relink` does)
  local old = root .. "/" .. A .. "/Backlog/TASKS/2026-01-01_alt.md"
  H.write(
    old,
    ("---\ntitle: Alt\nstatus: done\n---\n\n[Ziel](../../ROADMAP/tasks/%s.md)\n"):format(x.slug)
  )
  local before =
    { y = H.read(y.path), z = H.read(z.path), meeting = H.read(meeting), old = H.read(old) }

  local done = assert(mutate.done(x.id, o))
  local target = done.to
  local name = target:match("([^/]+)$")
  ok(
    H.read(y.path):find(
      ("[Ziel](../../Backlog/TASKS/%s) [Teil](./../../Backlog/TASKS/%s#k) [Andere](%s.md)"):format(
        name,
        name,
        w.slug
      ),
      1,
      true
    ),
    H.read(y.path)
  )
  ok(
    H.read(z.path):find(("[Ziel](../../../%s/Backlog/TASKS/%s)"):format(A, name), 1, true),
    H.read(z.path)
  )
  ok(
    H.read(meeting):find(("[Ziel](../Backlog/TASKS/%s)"):format(name), 1, true),
    "a meeting's link"
  )
  ok(
    H.read(target):find(("[Nachbar](../../ROADMAP/tasks/%s.md)"):format(y.slug), 1, true),
    "the task's own link"
  )
  eq(H.read(old), before.old, "the Backlog is not read by done")
  eq(done.relinked.links, 4)
  eq(#done.relinked.files, 3)
  eq(
    #mdlinks.missing(H.read(target), vim.fs.dirname(target)),
    0,
    "nothing dead in the finished file"
  )

  local reopened = assert(mutate.reopen(x.id, o))
  eq(H.read(y.path), before.y, "reopen gives the texts back")
  eq(H.read(z.path), before.z)
  eq(H.read(meeting), before.meeting)
  ok(H.read(x.path):find(("[Nachbar](%s.md)"):format(y.slug), 1, true), "and the task's own link")
  eq(
    reopened.etag_after,
    require("tasks_nvim.fsio").etag(H.read(x.path)),
    "the version reopen names is the file's"
  )

  -- relink = false leaves every link as it was
  local plain = assert(mutate.done(x.id, vim.tbl_extend("force", o, { relink = false })))
  eq(H.read(y.path), before.y, "relink = false")
  eq(plain.relinked, nil)
  assert(mutate.reopen(x.id, vim.tbl_extend("force", o, { relink = false })))

  -- ── move_area and back ──────────────────────────────────────────────────
  local moved = assert(moves.move(x.id, B, o))
  ok(
    H.read(y.path):find(("[Ziel](../../../%s/ROADMAP/tasks/%s.md)"):format(B, x.slug), 1, true),
    H.read(y.path)
  )
  ok(
    H.read(z.path):find(("[Ziel](%s.md)"):format(x.slug), 1, true),
    "a link from the new area is short"
  )
  ok(
    H.read(moved.to):find(("[Nachbar](../../../%s/ROADMAP/tasks/%s.md)"):format(A, y.slug), 1, true),
    "own link"
  )
  eq(moved.etag_after, require("tasks_nvim.fsio").etag(H.read(moved.to)))
  assert(moves.move(moved.new_id, A, vim.tbl_extend("force", o, { if_match = moved.etag_after })))
  eq(H.read(y.path), before.y, "move_area back gives the texts back")
  eq(H.read(z.path), before.z)
  eq(H.read(meeting), before.meeting)

  -- ── folderize: the others follow, the file's own links move once ─────────
  local fz = assert(mutate.folderize(x.id, o))
  ok(H.read(y.path):find(("[Ziel](%s/%s.md)"):format(x.slug, x.slug), 1, true), H.read(y.path))
  ok(
    H.read(fz.path):find(("[Nachbar](../%s.md)"):format(y.slug), 1, true),
    "shifted once, not twice"
  )
  -- a folder task finished: a link into its assets goes along with the folder
  H.write(vim.fs.dirname(fz.path) .. "/assets/bild.png", "png")
  H.write(w.path, H.read(w.path) .. ("\n![Bild](%s/assets/bild.png)\n"):format(x.slug))
  local fdone = assert(mutate.done(x.id, o))
  local stem = vim.fs.basename(vim.fs.dirname(fdone.to))
  ok(
    H.read(w.path):find(("![Bild](../../Backlog/TASKS/%s/assets/bild.png)"):format(stem), 1, true),
    H.read(w.path)
  )
  ok(
    H.read(y.path):find(("[Ziel](../../Backlog/TASKS/%s/%s.md)"):format(stem, stem), 1, true),
    H.read(y.path)
  )

  -- attach turns a plain task into a folder task: the links to it follow once the asset is there
  local png = H.tmpdir() .. "/anhang.png"
  H.write(png, "png")
  assert(mutate.attach(w.id, png, o))
  ok(H.read(y.path):find(("[Andere](%s/%s.md)"):format(w.slug, w.slug), 1, true), H.read(y.path))

  -- a file with nothing to change is read, never locked: a lock for each file below ROADMAP/ would be one lock file
  -- and one emptied read cache per file of the vault on every done
  local fsio = require("tasks_nvim.fsio")
  local real_lock, locks = fsio.with_lock, 0
  fsio.with_lock = function(...)
    locks = locks + 1
    return real_lock(...)
  end
  local none = relink.follow(root, {
    {
      from = root .. "/" .. A .. "/ROADMAP/tasks/gibt-es-nicht.md",
      to = root .. "/" .. A .. "/Backlog/TASKS/2026-01-01_gibt-es-nicht.md",
    },
  })
  local goal = new(A, "Lockziel")
  local from = new(A, "Lockquelle", ("\n[z](%s.md)\n"):format(goal.slug))
  local some = relink.follow(root, {
    { from = goal.path, to = root .. "/" .. A .. "/ROADMAP/tasks/woanders.md" },
  })
  fsio.with_lock = real_lock
  eq(none.links, 0)
  eq(#some.files, 1, "the one file that names it, not the generated index")
  ok(fsio.same_path(some.files[1], from.path), tostring(some.files[1]))
  eq(locks, 1, "a lock only for the file that is written")

  -- ── repair: the dead links of before ────────────────────────────────────
  local root2 = F.vault(H)

  local function file(rel, body)
    H.write(
      root2 .. "/" .. rel,
      "---\ntitle: T\nstatus: open\ncreated: 2026-10-01\n---\n\n" .. body
    )
    return root2 .. "/" .. rel
  end
  file(A .. "/Backlog/TASKS/2026-02-01_erledigt.md", "fertig\n")
  file(A .. "/ROADMAP/reports/bericht.md", "Bericht\n")
  file(A .. "/Backlog/TASKS/2026-02-01_doppelt.md", "a\n")
  file(B .. "/Backlog/TASKS/2026-02-02_doppelt.md", "b\n")
  local src = file(A .. "/ROADMAP/tasks/quelle.md", table.concat({
    "[e](erledigt.md) [d](../../../ALL/ROADMAP/tasks/doppelt.md) [n](nirgends.md) [ok](../reports/bericht.md)",
    "[w](https://x.org/erledigt.md) [m]($REPOS_DIR/erledigt.md)",
  }, "\n") .. "\n")
  -- a finished task's own link, written while it was open in ROADMAP/tasks
  local own = file(A .. "/Backlog/FEATURES/2026-03-01_frueher.md", "[b](../reports/bericht.md)\n")
  local src_before, own_before = H.read(src), H.read(own)

  local dry = relink.repair(root2, nil, { dry_run = true })
  eq(H.read(src), src_before, "a dry run writes nothing")
  eq(H.read(own), own_before)
  eq(dry.links, 2)
  eq(#dry.ambiguous, 1)
  eq(dry.ambiguous[1].target, "../../../ALL/ROADMAP/tasks/doppelt.md")
  eq(#dry.ambiguous[1].candidates, 2)
  eq(#dry.unresolved, 1)
  eq(dry.unresolved[1].target, "nirgends.md")

  local fixed = relink.repair(root2, { A }, {})
  eq(fixed.links, 2)
  ok(H.read(src):find("[e](../../Backlog/TASKS/2026-02-01_erledigt.md)", 1, true), H.read(src))
  ok(H.read(src):find("[m]($REPOS_DIR/erledigt.md)", 1, true), "a machine's path stays")
  ok(H.read(own):find("[b](../../ROADMAP/reports/bericht.md)", 1, true), H.read(own))
  eq(relink.repair(root2, { A }, {}).links, 0, "a second run has nothing to do")
  -- the one link to the area it named wins over the others
  H.write(src, H.read(src) .. "[d2](../../../cascade.nvim/ROADMAP/tasks/doppelt.md)\n")
  eq(relink.repair(root2, { A }, {}).links, 1, "a candidate in the area the link named wins")
  ok(
    H.read(src):find("[d2](../../../cascade.nvim/Backlog/TASKS/2026-02-02_doppelt.md)", 1, true),
    H.read(src)
  )

  -- the CLI: a dry run lists and sums up
  H.write(src, H.read(src) .. "[e2](erledigt.md)\n")
  local said = {}
  local code = cli.run({ "relink", A, "--dry-run", "--vault=" .. root2 }, {
    out = function(s)
      said[#said + 1] = s
    end,
    err = function(s)
      said[#said + 1] = s
    end,
  })
  eq(code, 0)
  local all = table.concat(said, "\n")
  ok(all:find("would%-relink\tlib%.nvim/ROADMAP/tasks/quelle%.md:%d+\terledigt%.md\t"), all)
  ok(
    all:find(
      "relink: would rewrite 1 link(s) in 1 file(s); 1 ambiguous, 1 without a file of that slug",
      1,
      true
    ),
    all
  )
  ok(H.read(src):find("[e2](erledigt.md)", 1, true), "the CLI's dry run writes nothing")
end
