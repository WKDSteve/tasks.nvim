-- TESTS/tasks_learn_view_spec.lua -- the learning tree in the editor (`tasks_nvim.ui.learn`): which file a buffer holds,
-- the point under the cursor, changing its mark (a path through `paths.point` on disk, a task or a changed buffer in
-- the buffer, the reason asked for [~] and [-]), the view (progress as virtual text, image placeholders, folds, keys
-- from `keys.learning`), and `:Tasks promote` / `unpromote` / `point` / `learn`.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local config = require("tasks_nvim.config")
  local learn = require("tasks_nvim.ui.learn")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")

  local ARROW = "\226\134\146"
  local root = F.vault(H)
  vault.set_root(root)

  local told = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    told[#told + 1] = tostring(msg)
  end
  local function said()
    local all = table.concat(told, "\n")
    told = {}
    return all
  end
  local real_input = vim.ui.input
  local answer -- what the reason question answers (nil: cancelled)
  local asked = 0
  vim.ui.input = function(_, cb)
    asked = asked + 1
    cb(answer)
  end

  local path_file = root .. "/lib.nvim/ROADMAP/paths/lua-lernen.md"
  local original = table.concat({
    "---", -- 1
    "title: Lua lernen", -- 2
    "status: doing", -- 3
    "updated: 2026-11-01", -- 4
    "---", -- 5
    "", -- 6
    "Warum: Plugins schreiben.", -- 7
    "", -- 8
    "## Lernpunkte", -- 9
    "", -- 10
    "- [ ] Lua lernen {#lua}", -- 11
    "  - [x] [Manual](https://www.lua.org/manual/5.4/)", -- 12
    "    > Notiz: Rangfolge.", -- 13
    "  - [ ] Syntax {#syntax}", -- 14
    "  - [ ] ![Diagramm](assets/images/syntax.svg)", -- 15
    "  - [ ] C-Compiler {#cc}", -- 16
    "    - [ ] K&R lesen", -- 17
    "", -- 18
    "## Notizen", -- 19
    "", -- 20
  }, "\n")
  H.write(path_file, original)

  ---@param path string
  ---@return integer buf
  local function open(path)
    vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end
  ---@param row integer
  local function at(row)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
  ---@param buf integer
  ---@param row integer
  ---@return string
  local function line(buf, row)
    return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  end

  -- ── which file a buffer holds ─────────────────────────────────────────────
  local buf = open(path_file)
  local loc = assert(learn.locate(buf))
  eq({ loc.id, loc.kind, loc.area }, { "lib.nvim/lua-lernen", "path", "lib.nvim" })
  H.write(root .. "/lib.nvim/ROADMAP/paths/folder/folder.md", "---\ntitle: F\n---\n")
  H.write(root .. "/lib.nvim/ROADMAP/paths/folder/other.md", "---\ntitle: O\n---\n")
  F.task(H, root, "lib.nvim", "plain-task", {}, "\nBody.\n")
  local scratch = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(scratch, root .. "/lib.nvim/ROADMAP/paths/folder/folder.md")
  eq(learn.locate(scratch).id, "lib.nvim/folder", "the folder form")
  vim.api.nvim_buf_set_name(scratch, root .. "/lib.nvim/ROADMAP/paths/folder/other.md")
  has(select(2, learn.locate(scratch)), "not a learning path or task file", "an asset is no path")
  vim.api.nvim_buf_set_name(scratch, root .. "/lib.nvim/ROADMAP/tasks/plain-task.md")
  eq({ learn.locate(scratch).id, learn.locate(scratch).kind }, { "lib.nvim/plain-task", "task" })
  vim.api.nvim_buf_set_name(scratch, H.tmpdir() .. "/elsewhere.md")
  has(select(2, learn.locate(scratch)), "not a file of the vault")
  vim.api.nvim_buf_delete(scratch, { force = true })

  -- ── the point under the cursor ─────────────────────────────────────────────
  local snap = learn.snapshot(buf)
  eq(snap.heading, 9)
  eq(learn.node_at(snap, 11).key, "lua")
  eq(learn.node_at(snap, 13).line + snap.offset, 12, "a note line belongs to its point")
  eq(learn.node_at(snap, 7), nil, "prose is no point")
  eq(learn.node_at(snap, 18), nil, "a blank line after the tree is no point")

  -- ── the mark: a path buffer without changes is written on disk ─────────────
  at(14)
  learn.cycle()
  has(H.read(path_file), "  - [x] Syntax {#syntax}\n", "open -> learned on disk")
  eq(line(buf, 14), "  - [x] Syntax {#syntax}", "the buffer was reloaded")
  ok(not vim.bo[buf].modified)
  eq(asked, 0, "learned asks for nothing")
  -- learned -> seen asks for the reason; a cancelled question changes nothing
  answer = nil
  learn.cycle()
  eq(asked, 1)
  has(H.read(path_file), "  - [x] Syntax {#syntax}\n", "cancelled: nothing written")
  answer = "   "
  learn.cycle()
  has(said(), "seen needs a reason")
  answer = "nur überflogen"
  learn.cycle()
  has(H.read(path_file), "  - [~] Syntax – Grund: nur überflogen {#syntax}\n")
  eq(line(buf, 14), "  - [~] Syntax – Grund: nur überflogen {#syntax}")
  -- seen -> dropped: the question is asked again, the old reason offered
  answer = "doch nicht nötig"
  learn.cycle()
  has(H.read(path_file), "  - [-] Syntax – Grund: doch nicht nötig {#syntax}\n")
  learn.cycle()
  has(H.read(path_file), "  - [ ] Syntax {#syntax}\n", "dropped -> open, the reason goes")
  -- a parent has no mark of its own
  at(11)
  learn.cycle()
  has(said(), "has no mark of its own")
  -- the file changed on disk below an unchanged buffer: refused, nothing written
  local disk_now = H.read(path_file)
  H.write(path_file, (disk_now:gsub("Syntax {#syntax}", "Syntax neu {#syntax}")))
  at(14)
  eq(
    select(2, learn.set_point(buf, 14, "learned")),
    "lib.nvim/lua-lernen changed on disk: reload the buffer (:edit) first"
  )
  has(H.read(path_file), "Syntax neu {#syntax}")
  H.write(path_file, disk_now)
  vim.cmd("silent edit!")

  -- a buffer with unsaved changes is changed in the buffer, the file stays
  vim.api.nvim_buf_set_lines(buf, 6, 7, false, { "Warum: Plugins schreiben (geändert)." })
  ok(vim.bo[buf].modified)
  assert(learn.set_point(buf, 14, "learned"))
  eq(line(buf, 14), "  - [x] Syntax {#syntax}")
  eq(H.read(path_file), disk_now, "the file on disk as it was")
  vim.cmd("silent edit!")

  -- `:Tasks point <state> <reason>`: the reason as the rest of the line
  at(14)
  learn.cmd_point({ args = { state = "seen" }, rest = { "kurz", "gelesen" }, flags = {}, kv = {} })
  has(H.read(path_file), "  - [~] Syntax – Grund: kurz gelesen {#syntax}\n")
  learn.cmd_point({ args = { state = "open" }, rest = { "x" }, flags = {}, kv = {} })
  has(said(), "open takes no reason")
  learn.cmd_point({ args = { state = "open" }, rest = {}, flags = {}, kv = {} })
  has(H.read(path_file), "  - [ ] Syntax {#syntax}\n")

  -- ── a task's own ## Lernpunkte: changed in the buffer ──────────────────────
  local task_path = F.task(
    H,
    root,
    "lib.nvim",
    "learn-task",
    { kind = "task" },
    "\nText.\n\n## Lernpunkte\n\n- [ ] Erster Punkt\n- [ ] Zweiter Punkt\n\n## Notizen\n"
  )
  local tbuf = open(task_path)
  local tsnap = learn.snapshot(tbuf)
  local first = tsnap.offset + tsnap.tree.nodes[1].line
  at(first)
  learn.cycle()
  eq(line(tbuf, first), "- [x] Erster Punkt")
  ok(vim.bo[tbuf].modified, "the task buffer is changed, not the file")
  lacks(H.read(task_path), "[x] Erster", "the file waits for :write")
  vim.cmd("silent write")

  -- ── the view ──────────────────────────────────────────────────────────────
  config.merge({ keys = { learning = { cycle = "<F5>", follow = "gf", bogus = "x" } } })
  has(table.concat(config.ignored(), "\n"), "keys.learning.bogus", "an unknown action is named")
  buf = open(path_file)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].foldmethod = "manual"
  learn.attach(buf)
  ok(learn.is_attached(buf))
  local function virt()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, learn.ns, 0, -1, { details = true })) do
      local d = m[4]
      local text = {}
      for _, chunk in ipairs(d.virt_text or {}) do
        text[#text + 1] = chunk[1]
      end
      for _, l in ipairs(d.virt_lines or {}) do
        for _, chunk in ipairs(l) do
          text[#text + 1] = chunk[1]
        end
      end
      out[#out + 1] = (m[2] + 1) .. ":" .. table.concat(text)
    end
    return table.concat(out, "\n")
  end
  local v = virt()
  has(
    v,
    "9:  1 gelernt \194\183 0 angeschaut \194\183 0 entf\195\164llt \194\183 3 offen",
    "the tree on the heading"
  )
  has(
    v,
    "11:  1 gelernt \194\183 0 angeschaut \194\183 0 entf\195\164llt \194\183 3 offen",
    "a parent's progress"
  )
  has(v, "16:  0 gelernt \194\183 0 angeschaut \194\183 0 entf\195\164llt \194\183 1 offen")
  has(v, "15:    [image] assets/images/syntax.svg (missing)", "a placeholder below the image")
  lacks(v, "14:", "a leaf gets no progress")
  -- folds: a parent starts one, its subtree lies in it
  eq(vim.wo[win].foldmethod, "expr")
  vim.api.nvim_win_call(win, function()
    eq(learn.foldexpr(11), ">1")
    eq(learn.foldexpr(12), "1")
    eq(learn.foldexpr(16), ">2")
    eq(learn.foldexpr(17), "2")
    eq(learn.foldexpr(18), "0", "a blank line after the tree")
    eq(learn.foldexpr(7), "0")
    eq(vim.fn.foldlevel(17), 2)
  end)
  -- the keys of keys.learning, buffer-local
  eq(vim.fn.maparg("<F5>", "n", false, true).buffer, 1)
  -- a change redraws: an image that exists now loses its "(missing)"
  H.write(root .. "/lib.nvim/ROADMAP/paths/assets/images/syntax.svg", "<svg/>")
  learn.refresh(buf)
  has(virt(), "15:    [image] assets/images/syntax.svg")
  lacks(virt(), "(missing)")
  -- the image: images.nvim when there, else the path
  local shown
  package.loaded["images"] = {
    show = function(p)
      shown = p
      return true
    end,
  }
  at(15)
  eq(learn.image(), "images")
  eq(
    vim.fs.normalize(shown),
    vim.fs.normalize(root .. "/lib.nvim/ROADMAP/paths/assets/images/syntax.svg")
  )
  package.loaded["images"] = nil
  local preview = require("tasks_nvim.ui.preview")
  local real_available = preview.available
  preview.available = function()
    return false, "no mdview"
  end
  eq(learn.image(), "text")
  has(said(), "image: ")
  preview.available = real_available
  eq(learn.image_path("/v/p.md", "assets/../x.png"), nil, "no way out of the folder")
  eq(learn.image_path("/v/p.md", "other/x.png"), nil, "only below assets/")
  -- off again: no virtual text, the window's folds as they were, no keys
  learn.detach(buf)
  eq(virt(), "")
  eq(vim.wo[win].foldmethod, "manual")
  eq(vim.fn.maparg("<F5>", "n"), "")
  learn.cmd_learn({ args = {}, rest = {}, flags = {}, kv = {} })
  ok(learn.is_attached(buf), "toggle: on")
  learn.cmd_learn({ args = { action = "toggle" }, rest = {}, flags = {}, kv = {} })
  ok(not learn.is_attached(buf), "toggle: off")
  config.merge({})

  -- ── promote and take back ─────────────────────────────────────────────────
  eq({ learn.point_arg("lib.nvim/lua-lernen#cc") }, { "lib.nvim/lua-lernen", "cc" })
  eq({ learn.point_arg("lib.nvim/lua-lernen#3") }, { "lib.nvim/lua-lernen", 3 })
  eq(learn.point_arg("lua-lernen#cc"), nil)
  buf = open(path_file)
  -- a changed buffer is refused: the engine writes the file
  vim.api.nvim_buf_set_lines(buf, 6, 7, false, { "Warum: anders." })
  at(16)
  eq(learn.promote_at(), nil)
  has(said(), "write the buffer first")
  vim.cmd("silent edit!")
  -- a dry run names the task and writes nothing
  at(16)
  learn.cmd_promote({ args = {}, rest = {}, flags = { ["dry-run"] = true }, kv = {} })
  has(said(), "would promote lib.nvim/lua-lernen#cc to lib.nvim/c-compiler")
  lacks(H.read(path_file), ARROW)
  learn.cmd_promote({ args = {}, rest = {}, flags = {}, kv = {} })
  has(said(), "promoted lib.nvim/lua-lernen#cc to lib.nvim/c-compiler")
  local made = assert(scan.find("lib.nvim/c-compiler", { root = root }))
  ok(
    vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(made.path),
    "the new task is open"
  )
  eq(
    line(buf, 16),
    "  - [ ] C-Compiler " .. ARROW .. " lib.nvim/c-compiler {#cc}",
    "the container was reloaded"
  )
  ok(not line(buf, 17):find("K&R", 1, true), "the subtree left the path")
  -- the promoted point: its mark belongs to the task; follow opens it
  vim.api.nvim_set_current_buf(buf)
  at(16)
  has(select(2, learn.set_point(buf, 16, "learned")), "belongs to lib.nvim/c-compiler")
  vim.cmd("silent buffer " .. buf)
  at(16)
  eq(vim.fs.normalize(learn.follow()), vim.fs.normalize(made.path))
  -- take it back by its id (the composer's argument), the container is reloaded again
  vim.api.nvim_set_current_buf(buf)
  learn.cmd_unpromote({
    args = { point = "lib.nvim/lua-lernen#cc" },
    rest = {},
    flags = {},
    kv = {},
  })
  has(said(), "took back lib.nvim/lua-lernen#cc")
  eq(line(buf, 16), "  - [ ] C-Compiler {#cc}")
  eq(line(buf, 17), "    - [ ] K&R lesen", "the subtree is back")
  eq(scan.find("lib.nvim/c-compiler", { root = root }), nil, "the task file is gone")
  -- and under the cursor
  at(16)
  learn.cmd_promote({ args = {}, rest = {}, flags = { title = "Compiler bauen" }, kv = {} })
  ok(scan.find("lib.nvim/compiler-bauen", { root = root }), "--title names the task")
  vim.api.nvim_set_current_buf(buf)
  at(16)
  learn.cmd_unpromote({ args = {}, rest = {}, flags = {}, kv = {} })
  eq(scan.find("lib.nvim/compiler-bauen", { root = root }), nil)
  at(14)
  learn.cmd_unpromote({ args = {}, rest = {}, flags = {}, kv = {} })
  has(said(), "was not promoted")
  learn.cmd_promote({ args = { point = "nope" }, rest = {}, flags = {}, kv = {} })
  has(said(), "not a learning point <area>/<slug>#<key|n>: nope")
  learn.cmd_promote({ args = {}, rest = { "stray" }, flags = {}, kv = {} })
  has(said(), "unexpected argument: stray")

  -- ── learning.auto: the view by itself on a path or a task with ## Lernpunkte, never on another file ─────────────
  vim.cmd("silent! %bwipeout!")
  learn.enable_auto(true)
  buf = open(path_file)
  ok(learn.is_attached(buf), "a path gets the view when it is shown")
  local plain = open(root .. "/lib.nvim/ROADMAP/tasks/plain-task.md")
  ok(not learn.is_attached(plain), "a task without ## Lernpunkte does not")
  learn.enable_auto(false)
  eq(
    pcall(vim.api.nvim_get_autocmds, { group = "TasksLearnAuto" }),
    false,
    "off: the group is gone"
  )
  local tbuf2 = open(task_path)
  ok(not learn.is_attached(tbuf2), "off: nothing attaches")

  -- ── :checkhealth names the optional plugins of the view ───────────────────
  local reported = {}
  local real_health = vim.health
  local function rec(msg)
    reported[#reported + 1] = tostring(msg)
  end
  vim.health = { start = rec, ok = rec, warn = rec, error = rec, info = rec }
  pcall(require("tasks_nvim.health").check)
  vim.health = real_health
  local health_text = table.concat(reported, "\n")
  has(health_text, "images.nvim")
  has(health_text, "emojis.nvim")

  vim.ui.input = real_input
  vim.notify = real_notify
  vault.set_root(nil)
  vim.cmd("silent! %bwipeout!")
end
