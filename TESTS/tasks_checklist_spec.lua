-- TESTS/tasks_checklist_spec.lua -- checklists (`tasks_nvim.checklist` and its operations): lists as folders
-- `_list-<slug>/`, an entry per file, `#tags` from the typed line, the filter, the text, delete with the attachments,
-- promote to a task with the attachments, `attach` and `board_save` on an entry, and the folders are no areas.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local checklist = require("tasks_nvim.checklist")
  local ops = require("tasks_nvim.ops")
  local fsio = require("tasks_nvim.fsio")
  local vault = require("tasks_nvim.vault")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local uploads = H.tmpdir() .. "/uploads"
  vim.fn.mkdir(uploads, "p")

  ---@param list table[]
  ---@return table[] results
  local function run(list)
    local doc, err = ops.run(
      { ops = list },
      { root = root, today = F.TODAY, attach = { upload_dir = uploads } }
    )
    eq(doc and doc.kind, "tasks.result", vim.inspect(err))
    return doc.results
  end
  local function one(op)
    return run({ op })[1]
  end

  -- ── the #words of a typed line ──────────────────────────────────────────────
  local title, tags = checklist.split_tags("Ticket #sap anlegen #Hiva")
  eq(title, "Ticket anlegen")
  eq(tags, { "sap", "Hiva" })
  title, tags = checklist.split_tags("C# und issue#4 bleiben")
  eq(title, "C# und issue#4 bleiben", "a # inside a word is text")
  eq(tags, {})
  eq(select(1, checklist.split_tags("#nur #tags")), "", "a line of tags only has no title")

  -- ── a list and its entries ──────────────────────────────────────────────────
  local made = one({ op = "checklist_new", title = "Support Fälle" })
  eq(made.ok, true, vim.inspect(made))
  eq(made.id, "_list-support-faelle")
  ok(fsio.is_file(root .. "/_list-support-faelle/list.md"), "the list has its list.md")
  local twice = one({ op = "checklist_new", title = "Support Fälle" })
  eq(twice.id, "_list-support-faelle-2", "a taken name gets a counter")
  local list = made.id

  local refused = one({ op = "entry_add", list = list, title = "#nur #tags" })
  eq(refused.ok, false, "a line of tags only is refused")
  eq(refused.error.code, "invalid_argument")
  local bad_tag = one({ op = "entry_add", list = list, title = "x", tags = { "a,b" } })
  eq(bad_tag.error and bad_tag.error.code, "invalid_argument", "a tag with a comma is refused")
  local no_list = one({ op = "entry_add", list = "_list-nichts", title = "x" })
  eq(no_list.error and no_list.error.code, "not_found", "an entry of a list that is not there")

  local first = one({
    op = "entry_add",
    list = list,
    title = "Erster #sap",
    fields = { created = "2026-01-05T08:00:00Z" },
  })
  eq(first.ok, true, vim.inspect(first))
  eq(first.id, list .. "/20260105-080000-erster", "the slug is the time and the title")
  local second = one({
    op = "entry_add",
    list = list,
    title = "Zweiter",
    tags = { "AI" },
    body = "Mit **Text**.",
    fields = { created = "2026-01-06T08:00:00Z" },
  })
  eq(second.ok, true, vim.inspect(second))
  local entries = checklist.entries(root, list)
  eq(#entries, 2)
  eq(entries[1].title, "Zweiter", "newest first")
  eq(entries[1].tags, { "ai" }, "tags are lower case")
  eq(entries[1].body, "Mit **Text**.")
  eq(entries[2].tags, { "sap" }, "the #word of the line is a tag")

  -- ── the filter ──────────────────────────────────────────────────────────────
  local function titles(list_)
    return vim.tbl_map(function(e)
      return e.title
    end, list_)
  end
  eq(titles(checklist.filter(entries, { since = "2026-01-06" })), { "Zweiter" })
  eq(titles(checklist.filter(entries, { ["until"] = "2026-01-05" })), { "Erster" })
  eq(titles(checklist.filter(entries, { tag = "SAP" })), { "Erster" }, "the tag is case folded")
  eq(
    titles(checklist.filter(entries, { q = "zweiter text" })),
    { "Zweiter" },
    "every word must be in it"
  )
  eq(
    titles(checklist.filter(entries, { q = "zweiter sap" })),
    {},
    "a word that is in no field: nothing"
  )
  eq(titles(checklist.filter(entries, { state = "done" })), {})

  -- ── tick, retitle, tags and text; the inverse puts it back ──────────────────
  local set = one({ op = "entry_set", id = second.id, done = true, tags = {}, body = "Neu" })
  eq(set.outcome, "changed", vim.inspect(set))
  local e2 = assert(checklist.find(second.id, root))
  eq(e2.done, F.TODAY)
  eq(e2.tags, {}, "an empty list removes the tags")
  eq(e2.body, "Neu")
  local text = H.read(e2.path)
  has(text, "title: Zweiter", "the frontmatter stays")
  ok(not text:find("tags", 1, true), "no tags line is left")
  local back = one(vim.deepcopy(set.inverse))
  eq(back.outcome, "changed", vim.inspect(back))
  e2 = assert(checklist.find(second.id, root))
  eq(
    { e2.done, e2.tags, e2.body },
    { nil, { "ai" }, "Mit **Text**." },
    "the inverse puts everything back"
  )
  eq(one({ op = "entry_set", id = second.id, title = "Zweiter" }).outcome, "unchanged")
  eq(
    one({ op = "entry_set", id = second.id, done = true, if_match = "sha256:0000000000000000" }).error.code,
    "conflict"
  )

  -- ── attach and board_save on an entry: the folder form, no area, no index ───
  H.write(uploads .. "/abc", "a picture")
  local att = one({
    op = "attach",
    id = first.id,
    from = "upload",
    upload = "abc",
    name = "shot.png",
    kind = "image",
  })
  eq(att.ok, true, vim.inspect(att))
  eq(att.asset, "assets/images/shot.png")
  eq(att.index, nil, "no index for a checklist")
  local folder = root .. "/" .. first.id .. "/"
  ok(fsio.is_file(folder .. "20260105-080000-erster.md"), "the entry is in its folder form")
  ok(fsio.is_file(folder .. "assets/images/shot.png"), "the attachment is there")
  ok(not fsio.is_dir(root .. "/" .. list .. "/ROADMAP"), "no ROADMAP in a list")
  H.write(uploads .. "/board.json", '{"strokes":[]}')
  H.write(uploads .. "/board.svg", "<svg/>")
  local board = one({
    op = "board_save",
    id = first.id,
    name = "skizze",
    format = "ink",
    upload = "board.json",
    preview = "board.svg",
  })
  eq(board.outcome, "created", vim.inspect(board))
  ok(
    fsio.is_file(folder .. "assets/boards/skizze.ink.json"),
    "the board is an attachment of the entry"
  )
  local names = vim.tbl_map(function(a)
    return a.name
  end, vault.areas(root))
  ok(not vim.tbl_contains(names, list), "a list is no area")

  -- ── delete: an entry with attachments goes with its folder and has no inverse ──
  local gone = one({ op = "entry_delete", id = first.id })
  eq(gone.outcome, "deleted", vim.inspect(gone))
  eq(gone.inverse, nil, "the attachments cannot be made again")
  ok(not fsio.is_dir(root .. "/" .. first.id), "the folder is gone")
  -- one without attachments comes back with its inverse
  local plain = one({ op = "entry_delete", id = second.id })
  ok(plain.inverse, "a plain entry can be made again")
  eq(one(vim.deepcopy(plain.inverse)).outcome, "created")
  e2 = assert(checklist.find(second.id, root))
  eq(
    { e2.title, e2.created, e2.tags, e2.body },
    { "Zweiter", "2026-01-06T08:00:00Z", { "ai" }, "Mit **Text**." }
  )

  -- ── promote: the task gets title, text, tags and attachments; the entry is gone ──
  H.write(uploads .. "/memo", "sound")
  eq(
    one({
      op = "attach",
      id = second.id,
      from = "upload",
      upload = "memo",
      name = "memo.ogg",
      kind = "audio",
    }).ok,
    true
  )
  eq(one({ op = "entry_promote", id = second.id, area = "nope" }).error.code, "invalid_argument")
  local up = one({ op = "entry_promote", id = second.id, area = "lib.nvim" })
  eq(up.ok, true, vim.inspect(up))
  eq(up.from, second.id)
  local task = assert(scan.find(up.id, { root = root }))
  eq(task.folder, true, "the task is a folder task")
  ok(
    fsio.is_file(fsio.dirname(task.path) .. "/assets/audio/memo.ogg"),
    "the attachment moved along"
  )
  eq(task.tags, { "ai" }, "the tags moved along")
  has(H.read(task.path), "Mit **Text**.")
  ok(not fsio.is_dir(root .. "/" .. second.id), "the entry is gone")
  eq(#checklist.entries(root, list), 0)

  -- ── a list goes only when it is empty; its inverse makes it again ───────────
  one({ op = "entry_add", list = list, title = "Bleibt" })
  eq(one({ op = "checklist_delete", id = list }).error.code, "conflict")
  local empty = one({ op = "checklist_delete", id = twice.id })
  eq(empty.outcome, "deleted", vim.inspect(empty))
  ok(not fsio.is_dir(root .. "/" .. twice.id))
  eq(one(vim.deepcopy(empty.inverse)).outcome, "created")
  eq(assert(checklist.list(root, twice.id)).title, "Support Fälle")

  -- ── a link in an entry's folder: not deleted, not followed ──────────────────
  local outside = H.tmpdir() .. "/outside"
  vim.fn.mkdir(outside, "p")
  H.write(outside .. "/keep.txt", "keep")
  local linked = one({ op = "entry_add", list = list, title = "Mit Link" })
  H.write(uploads .. "/x", "x")
  one({ op = "attach", id = linked.id, from = "upload", upload = "x", name = "x.txt" })
  local link = root .. "/" .. linked.id .. "/assets/link"
  local made_link = vim.uv.fs_symlink(outside, link, { junction = true, dir = true })
  if not made_link then
    print("n/a  no symbolic link or junction can be made here")
  else
    local denied = one({ op = "entry_delete", id = linked.id })
    eq(denied.ok, false, vim.inspect(denied))
    eq(denied.error.code, "forbidden")
    ok(fsio.is_file(outside .. "/keep.txt"), "what the link points at is untouched")
    vim.uv.fs_unlink(link)
  end
end
