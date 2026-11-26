-- TESTS/tasks_icon_cover_write_spec.lua -- writing `icon` and `cover`: `new`, `set` (an empty value removes), plans,
-- projects and paths (`plans.new` / `plans.set`), the write door (`new`, `plan_new`, `project_new`, `plan_set`,
-- `meeting_new`) and the CLI. A task without the fields is written as before.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local mutate = require("tasks_nvim.mutate")
  local plans = require("tasks_nvim.plans")
  local paths = require("tasks_nvim.paths")
  local scan = require("tasks_nvim.scan")
  local ops = require("tasks_nvim.ops")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY }

  -- UTF-8 by byte, so the file stays ASCII
  local CRAB = "\240\159\166\128" -- U+1F980
  local HASH_KEY = "#\239\184\143\226\131\163" -- # U+FE0F U+20E3: starts with # (a YAML comment if unquoted)
  local STAR_KEY = "*\239\184\143\226\131\163" -- * U+FE0F U+20E3: starts with * (a YAML alias if unquoted)
  local FAMILY = "\240\159\145\168\226\128\141\240\159\145\169\226\128\141\240\159\145\167"

  -- ── new: both written after links, read back the same ─────────────────────
  local made = assert(
    mutate.new(
      "lib.nvim",
      vim.tbl_extend(
        "force",
        o,
        { title = "With icon", icon = CRAB, cover = "assets/cover.png", folder = true }
      )
    )
  )
  local text = assert(H.read(made.path))
  has(text, "icon: " .. CRAB .. "\ncover: assets/cover.png\n")
  local task = assert(scan.find(made.id, { root = root }))
  eq(task.icon, { kind = "emoji", value = CRAB })
  eq(task.cover, "assets/cover.png")
  ok(task.valid, "valid")

  -- a task without them: no line, the same text as before the fields existed
  local plain = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "No icon" })))
  local plain_text = assert(H.read(plain.path))
  ok(not plain_text:find("icon:", 1, true), "no icon line")
  ok(not plain_text:find("cover:", 1, true), "no cover line")

  -- refused before anything is written
  local bad, berr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad icon", icon = "rocket" }))
  eq(bad, nil)
  has(berr, "unknown icon 'rocket'")
  ok(not H.exists(root .. "/lib.nvim/ROADMAP/tasks/bad-icon.md"), "nothing written")
  local _, cerr =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad cover", cover = "../c.png" }))
  has(cerr, "below assets/")

  -- ── set: every form, a value that YAML would misread is quoted, empty removes ─
  for _, v in ipairs({ HASH_KEY, STAR_KEY, FAMILY, "handshake", "assets/i.svg", CRAB }) do
    assert(mutate.set(plain.id, { icon = v }, o))
    local t = assert(scan.find(plain.id, { root = root }))
    eq(t.icon and t.icon.value, v, "set and read back: " .. v)
    ok(t.valid, "valid after set: " .. v)
  end
  local _, serr = mutate.set(plain.id, { icon = CRAB .. CRAB }, o)
  has(serr, "neither one emoji")
  eq(assert(scan.find(plain.id, { root = root })).icon.value, CRAB, "a refused set changes nothing")
  assert(mutate.set(plain.id, { cover = "assets/big.webp" }, o))
  eq(assert(scan.find(plain.id, { root = root })).cover, "assets/big.webp")
  assert(mutate.set(plain.id, { icon = mutate.REMOVE, cover = mutate.REMOVE }, o))
  local removed = assert(H.read(plain.path))
  ok(
    not removed:find("icon:", 1, true) and not removed:find("cover:", 1, true),
    "REMOVE drops both"
  )
  ok(vim.tbl_contains(mutate.SETTABLE, "icon") and vim.tbl_contains(mutate.SETTABLE, "cover"))

  -- ── plans, projects and paths ─────────────────────────────────────────────
  local plan = assert(
    plans.new("lib.nvim", vim.tbl_extend("force", o, { title = "Iconic plan", icon = CRAB }))
  )
  eq(assert(plans.find(plan.id, { root = root })).icon, { kind = "emoji", value = CRAB })
  local _, perr =
    plans.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad plan", icon = "nope" }))
  has(perr, "unknown icon")
  local project = assert(
    plans.new(
      "lib.nvim",
      vim.tbl_extend(
        "force",
        o,
        { title = "Iconic project", kind = "project", cover = "assets/p.jpg" }
      )
    )
  )
  eq(assert(require("tasks_nvim.projects").find(project.id, { root = root })).cover, "assets/p.jpg")
  local path = assert(
    paths.new("lib.nvim", vim.tbl_extend("force", o, { title = "Lua lernen", icon = "idea" }))
  )
  eq(assert(paths.find(path.id, { root = root })).icon, { kind = "word", value = "idea" })
  for _, kind in ipairs({ "plan", "project", "path" }) do
    ok(vim.tbl_contains(plans.SET_KEYS[kind], "icon"), kind .. " sets icon")
    ok(vim.tbl_contains(plans.SET_KEYS[kind], "cover"), kind .. " sets cover")
  end
  assert(paths.set(path.id, { icon = "assets/lua.svg", cover = "assets/lua.png" }, o))
  local p = assert(paths.find(path.id, { root = root }))
  eq(p.icon, { kind = "asset", value = "assets/lua.svg" })
  eq(p.cover, "assets/lua.png")
  local _, pserr, pinfo = plans.set(plan.id, { cover = "assets/x.gif" }, o)
  has(pserr, "no image")
  eq(pinfo.code, "invalid_argument")
  assert(paths.set(path.id, { icon = vim.NIL, cover = "" }, o))
  local p2 = assert(paths.find(path.id, { root = root }))
  eq(p2.icon, nil, "vim.NIL removes")
  eq(p2.cover, nil, "an empty text removes")

  -- ── the write door ────────────────────────────────────────────────────────
  local doc = assert(ops.run({
    ops = {
      {
        op = "new",
        area = "lib.nvim",
        title = "Door icon",
        fields = { icon = CRAB, cover = "assets/d.png" },
      },
      { op = "plan_new", area = "lib.nvim", title = "Door plan", icon = "review" },
      { op = "project_new", area = "lib.nvim", title = "Door project", cover = "assets/x.svg" },
    },
  }, { root = root, today = F.TODAY }))
  for i = 1, 3 do
    ok(doc.results[i].ok, vim.inspect(doc.results[i]))
  end
  eq(assert(scan.find(doc.results[1].id, { root = root })).icon.value, CRAB)
  eq(assert(plans.find(doc.results[2].id, { root = root })).icon.value, "review")
  local refused = assert(ops.run({
    ops = {
      { op = "new", area = "lib.nvim", title = "Door bad", fields = { icon = "rocket" } },
    },
  }, { root = root, today = F.TODAY }))
  ok(not refused.results[1].ok, "a bad icon is refused")
  local set_doc = assert(ops.run({
    ops = {
      {
        op = "plan_set",
        id = doc.results[2].id,
        patch = { icon = vim.NIL, cover = "assets/c.png" },
      },
    },
  }, { root = root, today = F.TODAY }))
  ok(set_doc.results[1].ok, vim.inspect(set_doc.results[1]))
  local after = assert(plans.find(doc.results[2].id, { root = root }))
  eq(after.icon, nil)
  eq(after.cover, "assets/c.png")
  local meeting = assert(ops.run({
    ops = {
      {
        op = "meeting_new",
        area = "lib.nvim",
        title = "Sync",
        fields = { date = "2026-11-24", icon = CRAB, cover = "assets/m.png" },
      },
    },
  }, { root = root, today = F.TODAY }))
  ok(meeting.results[1].ok, vim.inspect(meeting.results[1]))
  local m = assert(require("tasks_nvim.meetings").find(meeting.results[1].id, { root = root }))
  eq(m.icon, { kind = "emoji", value = CRAB })
  eq(m.cover, "assets/m.png")

  -- ── the CLI ───────────────────────────────────────────────────────────────
  local cli = require("tasks_nvim.cli")
  local out = {}
  local io_ = {
    out = function(s)
      out[#out + 1] = s
    end,
    err = function(s)
      out[#out + 1] = s
    end,
  }
  eq(
    cli.run({
      "new",
      "lib.nvim",
      "Cli icon",
      "--icon=handshake",
      "--cover=assets/c.png",
      "--vault=" .. root,
      "--today=" .. F.TODAY,
    }, io_),
    0,
    table.concat(out, "\n")
  )
  local cli_task = assert(scan.find("lib.nvim/cli-icon", { root = root }))
  eq(cli_task.icon, { kind = "word", value = "handshake" })
  eq(cli_task.cover, "assets/c.png")
  out = {}
  eq(
    cli.run({
      "plan-new",
      "lib.nvim",
      "Cli plan",
      "--icon=" .. CRAB,
      "--vault=" .. root,
      "--today=" .. F.TODAY,
    }, io_),
    0,
    table.concat(out, "\n")
  )
  eq(assert(plans.find("lib.nvim/cli-plan", { root = root })).icon.value, CRAB)

  -- ── check: an asset that is not there, image: as the old name of cover: ───
  local check = require("tasks_nvim.check")
  local meeting_dir = root .. "/lib.nvim/MEETINGS"
  H.write(
    meeting_dir .. "/old-sync.md",
    table.concat({
      "---",
      "title: Old",
      "status: planned",
      "date: 2026-11-25",
      "image: assets/o.png",
      "---",
      "Note.",
      "",
    }, "\n")
  )
  local function codes_of(res, id)
    local found = {}
    for _, f in ipairs(res.findings or {}) do
      -- nor the template comments a task made without text keeps (tasks_empty_template_body_spec)
      if f.id == id and f.code ~= "empty-template-body" then
        found[#found + 1] = f.code
      end
    end
    for _, f in ipairs(res.hints or {}) do
      -- this spec is about the cover codes: the missing-summary hint of a task made without text is not its subject
      if f.id == id and f.code ~= "summary-missing" then
        found[#found + 1] = f.code
      end
    end
    table.sort(found)
    return found
  end
  local res = assert(check.run({ root = root, today = F.TODAY }))
  eq(codes_of(res, made.id), { "cover-missing" }, "a folder task without its cover file")
  eq(codes_of(res, doc.results[1].id), { "cover-missing" }, "a plain task cannot hold its cover")
  eq(codes_of(res, project.id), { "cover-missing" }, "a project")
  eq(codes_of(res, doc.results[2].id), { "cover-missing" }, "a plan")
  eq(codes_of(res, plain.id), {}, "nothing to say about a task without the fields")
  eq(codes_of(res, plan.id), {}, "an emoji needs no file")
  eq(codes_of(res, meeting.results[1].id), { "meeting-image-missing" }, "a meeting")
  eq(codes_of(res, "lib.nvim/old-sync"), { "meeting-image-alias", "meeting-image-missing" })
  -- the files there: the finding goes, and a cover named only in the frontmatter is no unused asset
  local dir = vim.fs.dirname(made.path)
  H.write(dir .. "/assets/cover.png", "png")
  assert(mutate.set(made.id, { icon = "assets/i.svg" }, o))
  res = assert(check.run({ root = root, today = F.TODAY }))
  eq(codes_of(res, made.id), { "icon-missing" }, "the cover is there now, the icon is not")
  H.write(dir .. "/assets/i.svg", "<svg/>")
  res = assert(check.run({ root = root, today = F.TODAY }))
  eq(codes_of(res, made.id), {}, "both there, neither unused")

  -- ── the contract: the fields only when the file has them ──────────────────
  local api = require("tasks_nvim.api")
  local function call(method, params)
    -- one value: the reply is the text alone
    local reply = api.call(method, vim.json.encode({ params = params or vim.empty_dict() }), {
      root = root,
    })
    return vim.json.decode(reply)
  end
  local entry = call("task", { id = made.id }).task
  eq(entry.icon, { kind = "asset", value = "assets/i.svg" })
  eq(entry.cover, "assets/cover.png")
  local bare = call("task", { id = plain.id }).task
  eq(bare.icon, nil, "no icon key without the field")
  eq(bare.cover, nil, "no cover key without the field")
  local hello = call("hello")
  ok(vim.tbl_contains(hello.capabilities, "icon"), "capability icon")
  eq(hello.enums.icon_word, require("tasks_nvim.model").ICON_WORDS)
  local snap = call("snapshot")
  local seen = {}
  for _, f in ipairs(snap.plans or {}) do
    seen[f.id] = f
  end
  for _, f in ipairs(snap.projects or {}) do
    seen[f.id] = f
  end
  eq(seen[plan.id].icon, { kind = "emoji", value = CRAB }, "a plan in the snapshot")
  eq(seen[project.id].cover, "assets/p.jpg", "a project in the snapshot")
  local mdoc = call("meeting", { id = meeting.results[1].id }).meeting
  eq(mdoc.icon, { kind = "emoji", value = CRAB })
  eq(mdoc.cover, "assets/m.png")
  eq(mdoc.image, "assets/m.png", "image: the old name, the same value")

  -- ── the form: Icon: and Cover: lines, judged as set judges them ───────────
  local form = require("tasks_nvim.form")
  local function line_of(lines, prefix)
    for i, l in ipairs(lines) do
      if l:sub(1, #prefix) == prefix then
        return i
      end
    end
  end
  local lines = form.template({ area = "lib.nvim", title = "Form icon", icon = CRAB })
  eq(lines[line_of(lines, "Icon: ")], "Icon: " .. CRAB, "the template carries a given icon")
  ok(line_of(lines, "Cover: "), "a Cover: line")
  lines[line_of(lines, "Cover: ")] = "Cover: assets/c.webp"
  local values, errs = form.validate(form.parse(lines), { "lib.nvim" })
  eq(errs, {})
  eq(values.opts.icon, CRAB)
  eq(values.opts.cover, "assets/c.webp")
  lines[line_of(lines, "Icon: ")] = "Icon: rocket"
  lines[line_of(lines, "Cover: ")] = "Cover: c.png"
  local _, errs2 = form.validate(form.parse(lines), { "lib.nvim" })
  eq(#errs2, 2, vim.inspect(errs2))
  ok(errs2[1]:find("^Icon: unknown icon"), errs2[1])
  ok(errs2[2]:find("^Cover: "), errs2[2])
  local empty = form.template({ area = "lib.nvim", title = "No icon" })
  local v3 = form.validate(form.parse(empty), { "lib.nvim" })
  eq(v3.opts.icon, nil, "an empty Icon: line sets nothing")
  eq(v3.opts.cover, nil)

  -- ── the form UI: <C-e> asks emojis.nvim, which writes into the Icon: line ─
  local ui_form = require("tasks_nvim.ui.form")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Title: x", "Icon: old", "Cover: " })
  local saved = package.loaded["emojis"]
  package.loaded["emojis"] = {
    insert = function()
      -- what emojis.nvim's insert picker does with a pick: put it at the cursor
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local l = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      vim.api.nvim_buf_set_lines(
        buf,
        row - 1,
        row,
        false,
        { l:sub(1, col) .. CRAB .. l:sub(col + 1) }
      )
    end,
  }
  ok(ui_form.pick_icon(buf), "picked")
  local after_pick = form.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq(vim.trim(after_pick.icon), CRAB, "the old value is replaced by the pick")
  package.loaded["emojis"] = false
  ok(not ui_form.pick_icon(buf), "without emojis.nvim nothing is picked")
  eq(vim.api.nvim_win_get_cursor(0)[1], 2, "the cursor is on the Icon: line")
  package.loaded["emojis"] = saved
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(require("tasks_nvim.config").get().keys.form.icon, "<C-e>")

  -- `:Tasks new icon=... cover=...` without an area opens the form with both filled in
  local cmd = require("tasks_nvim.ui.cmd")
  require("tasks_nvim.vault").set_root(root)
  local captured
  cmd.form_open = function(spec)
    captured = spec
  end
  cmd.task_new({
    args = { area = nil },
    kv = { icon = CRAB, cover = "assets/f.png" },
    flags = {},
    rest = {},
    range = { range = 0, line1 = 1, line2 = 1 },
  })
  cmd.form_open = nil
  ok(captured, "the form was opened")
  eq(captured.icon, CRAB, "icon= pre-fills the form")
  eq(captured.cover, "assets/f.png", "cover= too")

  -- `tasks show` names both
  out = {}
  eq(cli.run({ "show", made.id, "--vault=" .. root, "--today=" .. F.TODAY }, io_), 0)
  local shown = table.concat(out, "")
  has(shown, "icon: assets/i.svg (asset)")
  has(shown, "cover: assets/cover.png")
end
