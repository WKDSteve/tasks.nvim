-- TESTS/tasks_attach_op_spec.lua -- `attach` of the write door: the clipboard image or the newest screenshot becomes an asset
-- of a task, the answer carries the asset and its link, a dry run writes nothing, and what is wrong is refused.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local ops = require("tasks_nvim.ops")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local PNG = "\137PNG\r\n\26\n" .. "image-bytes"

  ---@param stdout string
  ---@return table
  local function clipboard(stdout)
    return {
      platform = "linux",
      has = function(exe)
        return exe == "wl-paste"
      end,
      system = function()
        return { code = stdout ~= "" and 0 or 1, stdout = stdout }
      end,
    }
  end

  ---@param list table[]
  ---@param extra? table   # request fields (`dry_run`)
  ---@param attach? table  # the seams of `attach_source` (a fake clipboard, the folders)
  ---@return table entry
  local function one(list, extra, attach)
    -- `tasks_nvim.ops.run`, not `api.call`: the seams are options of the engine, a request can never carry them
    local doc, err = ops.run(
      vim.tbl_extend("force", { ops = list }, extra or {}),
      { root = root, today = F.TODAY, attach = attach }
    )
    eq(doc and doc.kind, "tasks.result", vim.inspect(err))
    return doc.results[1]
  end

  local function new_task(title)
    return assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title })))
  end

  -- ── the clipboard image becomes an asset ───────────────────────────────────
  local a = new_task("Attach by clipboard")
  local e = one({ { op = "attach", id = a.id, from = "clipboard", name = "shot.png" } }, nil, {
    clipboard = clipboard(PNG),
  })
  eq(e.ok, true, vim.inspect(e))
  eq(e.outcome, "changed")
  eq(e.id, a.id)
  eq(e.asset, "assets/screenshots/shot.png", "the asset is named relative to the task folder")
  eq(e.link, "![shot.png](assets/screenshots/shot.png)", "the answer carries the link")
  eq(e.changed_ids[1], a.id)
  ok(e.etag_after, "the version after is told")
  local task = assert(scan.find(a.id, { root = root }))
  eq(task.folder, true, "a plain task became a folder task")
  eq(
    fsio.is_file(fsio.dirname(task.path) .. "/assets/screenshots/shot.png"),
    true,
    "the image is in assets/screenshots/"
  )
  eq(
    e.file,
    "lib.nvim/ROADMAP/tasks/" .. a.id:match("([^/]+)$") .. "/" .. a.id:match("([^/]+)$") .. ".md"
  )

  -- without a name the asset is called <slug>-<date>-<HHMM>.png and never replaces another
  local e2 = one({ { op = "attach", id = a.id, from = "clipboard" } }, nil, {
    clipboard = clipboard(PNG),
  })
  eq(e2.ok, true, vim.inspect(e2))
  local slug = a.id:match("([^/]+)$")
  ok(
    e2.asset:match(
      "^assets/screenshots/" .. slug:gsub("%p", "%%%0") .. "%-%d%d%d%d%-%d%d%-%d%d%-%d%d%d%d%.png$"
    ),
    "the default name is <slug>-<date>-<HHMM>.png: " .. e2.asset
  )

  -- ── no image on the clipboard: a clear failure, nothing created ───────────
  local b = new_task("Attach nothing")
  local none = one({ { op = "attach", id = b.id, from = "clipboard" } }, nil, {
    clipboard = clipboard(""),
  })
  eq(none.ok, false)
  eq(none.outcome, "failed")
  eq(none.error.code, "invalid_argument")
  eq(assert(scan.find(b.id, { root = root })).folder, false, "the task stays a plain file")

  -- ── the newest screenshot of a folder ─────────────────────────────────────
  local shots = H.tmpdir() .. "/shots"
  vim.fn.mkdir(shots, "p")
  vim.fn.writefile({ PNG }, shots .. "/new.png", "b")
  local c = new_task("Attach latest")
  local latest = one({ { op = "attach", id = c.id, from = "latest", name = "latest.png" } }, nil, {
    dirs = { shots },
  })
  eq(latest.ok, true, vim.inspect(latest))
  eq(latest.asset, "assets/screenshots/latest.png")

  -- too old: told, not guessed
  local d = new_task("Attach too old")
  local old = one({ { op = "attach", id = d.id, from = "latest" } }, nil, {
    dirs = { shots },
    now = os.time() + 24 * 3600,
  })
  eq(old.ok, false, "a screenshot older than the limit is not taken")
  eq(assert(scan.find(d.id, { root = root })).folder, false)

  -- ── a dry run writes nothing ──────────────────────────────────────────────
  local f = new_task("Attach dry")
  local dry = one(
    { { op = "attach", id = f.id, from = "clipboard", name = "dry.png" } },
    { dry_run = true },
    { clipboard = clipboard(PNG) }
  )
  eq(dry.ok, true, vim.inspect(dry))
  eq(dry.outcome, "would_change")
  eq(#dry.changed_ids, 0)
  eq(
    assert(scan.find(f.id, { root = root })).folder,
    false,
    "a dry run leaves the task a plain file"
  )

  -- ── what is wrong is refused ──────────────────────────────────────────────
  ---@param op table
  ---@param code string
  ---@param what string
  local function refused(op, code, what)
    -- through the front door (`api.call`), which has no seam to a clipboard: a request that got further would fail
    -- on the machine's own one
    local text =
      api.call("ops", vim.json.encode({ ops = { op } }), { root = root, today = F.TODAY })
    local doc = vim.json.decode(text)
    -- a request that is wrong in shape is a `tasks.error` (`code` on top); an operation that fails has it in its entry
    local err = doc.kind == "tasks.error" and doc or (doc.results[1] and doc.results[1].error)
    ok(err, what .. ": " .. text)
    eq(err.code, code, what .. ": " .. text)
  end
  refused({ op = "attach", from = "clipboard" }, "invalid_argument", "needs an id")
  refused({ op = "attach", id = a.id }, "invalid_argument", "needs a source")
  refused({ op = "attach", id = a.id, from = "file" }, "invalid_argument", "unknown source")
  refused(
    { op = "attach", id = a.id, from = "latest", dir = "/etc" },
    "invalid_argument",
    "no folder from outside"
  )
  refused(
    { op = "attach", id = "lib.nvim/never-was", from = "clipboard" },
    "not_found",
    "unknown task"
  )

  -- ── the folders a caller names (`attach_dirs`, the hub from its settings) ─
  ---@param request table
  ---@return table doc
  local function front(request)
    local text = api.call("ops", vim.json.encode(request), { root = root, today = F.TODAY })
    return vim.json.decode(text)
  end
  vim.fn.writefile({ PNG }, shots .. "/named.png", "b")
  local g = new_task("Attach from a named folder")
  local named = front({
    attach_dirs = { shots },
    ops = { { op = "attach", id = g.id, from = "latest", name = "named.png" } },
  })
  eq(named.results and named.results[1].ok, true, vim.inspect(named))
  eq(
    named.results[1].asset,
    "assets/screenshots/named.png",
    "the newest image of the folder that was named"
  )

  -- a named folder without a new image: refused, and the answer names no folder and no file of this machine
  local empty = H.tmpdir() .. "/no-shots-here"
  vim.fn.mkdir(empty, "p")
  local k = new_task("Attach from an empty folder")
  local quiet =
    front({ attach_dirs = { empty }, ops = { { op = "attach", id = k.id, from = "latest" } } })
  local qerr = quiet.results and quiet.results[1].error
  eq(qerr and qerr.code, "invalid_argument", vim.inspect(quiet))
  ok(not qerr.message:find("no-shots-here", 1, true), "the folder is not named: " .. qerr.message)

  -- named, and none: only the clipboard, never the folders of the system
  local h = new_task("Attach with no folder")
  local nofolder =
    front({ attach_dirs = {}, ops = { { op = "attach", id = h.id, from = "latest" } } })
  local nerr = nofolder.results and nofolder.results[1].error
  eq(nerr and nerr.code, "invalid_argument", vim.inspect(nofolder))
  ok(nerr.message:find("no screenshot folders", 1, true), nerr.message)
  eq(assert(scan.find(h.id, { root = root })).folder, false, "nothing was attached")

  -- a folder that is not absolute, too many folders, not a list of words: the request is refused as a whole
  for _, bad in ipairs({ { "shots" }, vim.fn["repeat"]({ shots }, 9), { 5 } }) do
    local doc =
      front({ attach_dirs = bad, ops = { { op = "attach", id = h.id, from = "latest" } } })
    eq(doc.kind, "tasks.error", vim.inspect(doc))
    eq(doc.code, "invalid_argument", vim.inspect(doc))
  end

  -- ── an upload: a file from the caller's folder ──────────────────────────────
  local inbox = H.tmpdir() .. "/uploads"
  vim.fn.mkdir(inbox, "p")
  local function put(file, text)
    local fd = assert(io.open(inbox .. "/" .. file, "wb"))
    fd:write(text)
    fd:close()
  end
  local u = new_task("Attach by upload")
  put("abc123", "a file of any kind")
  local up = one(
    { { op = "attach", id = u.id, from = "upload", upload = "abc123", name = "report.pdf" } },
    nil,
    { upload_dir = inbox }
  )
  eq(up.ok, true, vim.inspect(up))
  eq(up.asset, "assets/report.pdf")
  local uploaded = assert(scan.find(u.id, { root = root }))
  eq(uploaded.folder, true, "a plain task became a folder task")
  ok(fsio.is_file(vim.fs.dirname(uploaded.path) .. "/assets/report.pdf"), "the asset is there")
  ok(fsio.is_file(inbox .. "/abc123"), "the file stays: the caller takes it away")

  -- A name that is taken gets a counter: the name is the page's, and what is there is not replaced.
  local again = one(
    { { op = "attach", id = u.id, from = "upload", upload = "abc123", name = "report.pdf" } },
    nil,
    { upload_dir = inbox }
  )
  eq(again.asset, "assets/report-2.pdf", vim.inspect(again))

  -- `kind`: the asset goes into the folder of its kind below `assets/`, and the link names that folder. Without a kind
  -- an upload lies in `assets/` itself (above); the clipboard and the screenshot folders are screenshots (above).
  local kd = new_task("Attach by kind")
  for _, case in ipairs({
    {
      kind = "video",
      name = "clip.webm",
      rel = "assets/videos/clip.webm",
      link = "[clip.webm](assets/videos/clip.webm)",
    },
    {
      kind = "image",
      name = "photo.jpg",
      rel = "assets/images/photo.jpg",
      link = "![photo.jpg](assets/images/photo.jpg)",
    },
    {
      kind = "screenshot",
      name = "screen.png",
      rel = "assets/screenshots/screen.png",
      link = "![screen.png](assets/screenshots/screen.png)",
    },
  }) do
    local kinded = one({
      {
        op = "attach",
        id = kd.id,
        from = "upload",
        upload = "abc123",
        name = case.name,
        kind = case.kind,
      },
    }, nil, { upload_dir = inbox })
    eq(kinded.ok, true, vim.inspect(kinded))
    eq(kinded.asset, case.rel, "the asset names the folder of its kind")
    eq(kinded.link, case.link, "and so does the link")
    local kt = assert(scan.find(kd.id, { root = root }))
    ok(fsio.is_file(vim.fs.dirname(kt.path) .. "/" .. case.rel), case.rel .. " is there")
    ok(
      not fsio.is_file(vim.fs.dirname(kt.path) .. "/assets/" .. case.name),
      "and not in assets/ itself"
    )
  end
  -- A taken name gets its counter inside the folder of the kind; the same name in another folder is another asset.
  local counted = one({
    {
      op = "attach",
      id = kd.id,
      from = "upload",
      upload = "abc123",
      name = "clip.webm",
      kind = "video",
    },
  }, nil, { upload_dir = inbox })
  eq(counted.asset, "assets/videos/clip-2.webm", vim.inspect(counted))
  local elsewhere = one({
    { op = "attach", id = kd.id, from = "upload", upload = "abc123", name = "clip.webm" },
  }, nil, { upload_dir = inbox })
  eq(elsewhere.asset, "assets/clip.webm", vim.inspect(elsewhere))
  -- `exact` looks into the folder of the kind: taken there is `exists`, the same name without a kind is free.
  local taken_kind = one({
    {
      op = "attach",
      id = kd.id,
      from = "upload",
      upload = "abc123",
      name = "photo.jpg",
      kind = "image",
      exact = true,
    },
  }, { dry_run = true }, { upload_dir = inbox })
  eq((taken_kind.error or {}).code, "exists", vim.inspect(taken_kind))
  local free_flat = one({
    {
      op = "attach",
      id = kd.id,
      from = "upload",
      upload = "abc123",
      name = "photo.jpg",
      exact = true,
    },
  }, { dry_run = true }, { upload_dir = inbox })
  eq(free_flat.ok, true, vim.inspect(free_flat))
  -- A kind that is none is refused before anything is read or made, in a dry run too, also for the clipboard.
  local kb = new_task("Attach by a bad kind")
  for _, bad in ipairs({ "videos", "", "../x", "Video" }) do
    for _, dry_look in ipairs({ false, true }) do
      local no_kind = one({
        {
          op = "attach",
          id = kb.id,
          from = "upload",
          upload = "abc123",
          name = "x.bin",
          kind = bad,
        },
      }, dry_look and { dry_run = true } or nil, { upload_dir = inbox })
      eq(no_kind.ok, false, vim.inspect(no_kind))
      eq((no_kind.error or {}).code, "invalid_argument", vim.inspect(no_kind))
      ok(tostring(no_kind.error.message):find("kind must be", 1, true), vim.inspect(no_kind))
    end
  end
  local bad_clip = one(
    { { op = "attach", id = kb.id, from = "clipboard", kind = "nope" } },
    nil,
    { clipboard = clipboard(PNG) }
  )
  eq((bad_clip.error or {}).code, "invalid_argument", vim.inspect(bad_clip))
  eq(assert(scan.find(kb.id, { root = root })).folder, false, "the task was not touched")
  -- The clipboard with a kind named goes where the kind says.
  local clip_image = one(
    { { op = "attach", id = kb.id, from = "clipboard", name = "pasted.png", kind = "image" } },
    nil,
    { clipboard = clipboard(PNG) }
  )
  eq(clip_image.asset, "assets/images/pasted.png", vim.inspect(clip_image))

  -- `exact`: the name or nothing. A file sent again after its answer was lost is not attached twice, and a dry run (the
  -- hub's look before the transfer) says so already; the message names no path.
  for _, dry_look in ipairs({ false, true }) do
    local twice = one({
      {
        op = "attach",
        id = u.id,
        from = "upload",
        upload = "abc123",
        name = "report.pdf",
        exact = true,
      },
    }, dry_look and { dry_run = true } or nil, { upload_dir = inbox })
    eq(twice.ok, false, vim.inspect(twice))
    eq((twice.error or {}).code, "exists", vim.inspect(twice))
    ok(
      not tostring((twice.error or {}).message):find(root, 1, true),
      "no path: " .. vim.inspect(twice)
    )
  end
  ok(not fsio.is_file(vim.fs.dirname(uploaded.path) .. "/assets/report-3.pdf"), "no third copy")
  local fresh = one({
    {
      op = "attach",
      id = u.id,
      from = "upload",
      upload = "abc123",
      name = "voice.webm",
      exact = true,
    },
  }, nil, { upload_dir = inbox })
  eq(fresh.asset, "assets/voice.webm", vim.inspect(fresh))
  local wrong = one({ { op = "attach", id = u.id, from = "clipboard", exact = true } })
  eq((wrong.error or {}).code, "invalid_argument", vim.inspect(wrong))
  ok(
    tostring((wrong.error or {}).message):find("exact belongs to from", 1, true),
    vim.inspect(wrong)
  )

  -- A dry run looks at nothing.
  local v = new_task("Attach by upload, dry")
  local dry_upload = one(
    { { op = "attach", id = v.id, from = "upload", upload = "not-there", name = "x.txt" } },
    { dry_run = true },
    { upload_dir = inbox }
  )
  eq(dry_upload.outcome, "would_change", vim.inspect(dry_upload))
  eq(assert(scan.find(v.id, { root = root })).folder, false, "nothing was attached")

  -- What is wrong is refused, and names no path.
  for _, bad in ipairs({
    { { from = "upload", upload = "abc123", name = "x.txt" }, nil, "no upload folder" },
    { { from = "upload", name = "x.txt" }, inbox, "plain file name" },
    { { from = "upload", upload = "../abc123", name = "x.txt" }, inbox, "plain file name" },
    { { from = "upload", upload = "a\\b", name = "x.txt" }, inbox, "plain file name" },
    { { from = "upload", upload = "C:abc", name = "x.txt" }, inbox, "plain file name" },
    { { from = "upload", upload = "abc123" }, inbox, "needs a name" },
    { { from = "upload", upload = "gone", name = "x.txt" }, inbox, "the upload is not there" },
    { { from = "clipboard", upload = "abc123" }, inbox, "belongs to from" },
  }) do
    local op = vim.tbl_extend("force", { op = "attach", id = v.id }, bad[1])
    local res = one({ op }, nil, bad[2] and { upload_dir = bad[2] } or {})
    eq(res.ok, false, vim.inspect(res))
    local why = res.error or {}
    eq(why.code, "invalid_argument", vim.inspect(res))
    ok(tostring(why.message):find(bad[3], 1, true), vim.inspect(res))
    ok(not tostring(why.message):find(inbox, 1, true), "no path: " .. tostring(why.message))
  end
  eq(assert(scan.find(v.id, { root = root })).folder, false, "nothing was attached")

  -- The front door takes the folder as a request field, absolute only.
  local bad_dir = front({
    upload_dir = "uploads",
    ops = { { op = "attach", id = v.id, from = "upload", upload = "abc123", name = "x.txt" } },
  })
  eq(bad_dir.kind, "tasks.error", vim.inspect(bad_dir))
  eq(bad_dir.code, "invalid_argument", vim.inspect(bad_dir))
  local by_door = front({
    upload_dir = inbox,
    ops = { { op = "attach", id = v.id, from = "upload", upload = "abc123", name = "x.txt" } },
  })
  eq(by_door.kind, "tasks.result", vim.inspect(by_door))
  eq(by_door.results[1].asset, "assets/x.txt", vim.inspect(by_door))

  -- ── a copy is whole or not there ────────────────────────────────────────────
  local target = inbox .. "/whole.bin"
  put("source", "the content")
  -- What a killed copy left: it is not taken for the file, and the next copy goes over it.
  put("whole.bin.part", "half")
  ok(fsio.copy_whole(inbox .. "/source", target))
  eq(vim.fn.readblob(target), "the content")
  eq(vim.uv.fs_stat(target .. ".part"), nil, "no part stays")
  local copied, cerr = fsio.copy_whole(inbox .. "/source", target)
  eq(copied, false)
  ok(fsio.is_copy_exists(cerr), tostring(cerr))
  eq(vim.uv.fs_stat(target .. ".part"), nil, "none from a copy that was refused")
end
