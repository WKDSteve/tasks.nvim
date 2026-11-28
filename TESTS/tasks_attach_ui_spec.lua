-- TESTS/tasks_attach_ui_spec.lua -- the "attach a screenshot" entries of the editor: the new-task form (a third
-- @scans-data (what it lists is a fixture vault in a temp folder; a changed helper of TESTS/ selects it anyway)
-- answer to "attach assets?") and the dashboard (an action, and the entry of the plain list). All of them end in
-- `cmd.attach_screenshot`, which is the clipboard image, else the newest screenshot, through the same
-- `attach_source` as `:Tasks attach <id> from=...`. The clipboard and the screenshot folder are fakes behind the
-- `cmd.attach_opts` seam.

---@diagnostic disable: duplicate-set-field, param-type-mismatch, need-check-nil
-- Why: specs replace module functions with test doubles on purpose; a nil fails at the assert() that binds it.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local cmd = require("tasks_nvim.ui.cmd")
  local dash = require("tasks_nvim.ui.dash")
  local confirm = require("tasks_nvim.ui.confirm")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)
  local NOW = os.time({ year = 2026, month = 10, day = 19, hour = 14, min = 32, sec = 10 })
  local PNG = "\137PNG\r\n\26\n" .. "image-bytes"

  local orig = { notify = vim.notify, choose = confirm.choose, select = vim.ui.select }
  ---@type string[]
  local notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = tostring(msg)
  end
  local function said()
    return table.concat(notes, "\n")
  end

  ---A clipboard that holds `stdout` (linux/wl-paste) or nothing.
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

  local empty_dir = H.tmpdir() .. "/no-screenshots"
  vim.fn.mkdir(empty_dir, "p")

  ---@param clip string
  ---@param dir? string
  local function seam(clip, dir)
    cmd.attach_opts = {
      root = root,
      today = F.TODAY,
      now = NOW,
      dirs = { dir or empty_dir },
      clipboard = clipboard(clip),
    }
  end

  local function new_task(title)
    return assert(mutate.new("lib.nvim", { root = root, today = F.TODAY, title = title }))
  end

  local ok_run, err = pcall(function()
    -- ── the clipboard image is attached, and the task becomes a folder task ──
    local t1 = new_task("From the clipboard")
    seam(PNG)
    local res = cmd.attach_screenshot(t1.id)
    ok(res, "the clipboard image is attached")
    local folder = scan.find(t1.id, { root = root })
    ok(
      folder and folder.path:match("/from%-the%-clipboard/from%-the%-clipboard%.md$"),
      "a folder task now"
    )
    ok(vim.uv.fs_stat(vim.fs.dirname(folder.path) .. "/" .. res.rel), "the asset is in assets/")
    has(said(), "attached " .. t1.id, "said so")

    ok(
      res.rel:find("^assets/screenshots/"),
      "a screenshot lies in assets/screenshots/: " .. res.rel
    )

    -- ── `:Tasks attach <id> <file> kind=video`: the file goes into the folder of its kind ──
    local movie = H.tmpdir() .. "/ui-movie.webm"
    local mh = assert(io.open(movie, "wb"))
    mh:write("video")
    mh:close()
    notes = {}
    cmd.task_attach({
      rest = {},
      args = { id = t1.id, file = movie },
      kv = { from = "", name = "", dir = "", kind = "video" },
    })
    ok(
      vim.uv.fs_stat(vim.fs.dirname(folder.path) .. "/assets/videos/ui-movie.webm"),
      "the video is in assets/videos/: " .. said()
    )
    notes = {}
    cmd.task_attach({
      rest = {},
      args = { id = t1.id, file = movie },
      kv = { from = "", name = "", dir = "", kind = "movies" },
    })
    has(said(), "kind= takes", "an unknown kind is refused")
    eq(
      vim.uv.fs_stat(vim.fs.dirname(folder.path) .. "/assets/ui-movie.webm"),
      nil,
      "and nothing was attached"
    )

    -- ── `:Tasks attach <id> from=clipboard` does not wait for the clipboard program ──
    -- A stand-in for vim.system whose wait() throws: the program must be read through its exit callback.
    local real_system = vim.system
    local real_clip = require("lib.nvim.clipboard_image")
    local spawned = {}
    vim.system = function(argv, _, on_exit)
      spawned[#spawned + 1] = { argv = argv, on_exit = on_exit }
      return {
        wait = function()
          error("from=clipboard waited for the clipboard program", 0)
        end,
      }
    end
    local function shots_of(id)
      local t = assert(scan.find(id, { root = root }))
      return vim.fn.glob(vim.fs.dirname(t.path) .. "/assets/screenshots/*", false, true)
    end
    local sys_ok, sys_err = pcall(function()
      local function from_clipboard(id)
        cmd.task_attach({
          rest = {},
          args = { id = id },
          kv = { from = "clipboard", name = "", dir = "", kind = "" },
        })
      end
      local function attached_said(id)
        vim.wait(1000, function()
          return said():find("attached " .. id, 1, true) ~= nil
        end, 5)
        return said():find("attached " .. id, 1, true) ~= nil
      end
      cmd.attach_opts = {
        root = root,
        today = F.TODAY,
        now = NOW,
        clipboard = {
          platform = "linux",
          has = function(exe)
            return exe == "wl-paste"
          end,
        },
      }
      local t5 = new_task("Clipboard later")
      notes = {}
      from_clipboard(t5.id)
      eq(#spawned, 1, "the clipboard program was started")
      eq(spawned[1].argv[1], "wl-paste", "the program of the platform")
      ok(type(spawned[1].on_exit) == "function", "with an exit callback, not a wait")
      lacks(said(), "attached", "nothing is attached before the program answers")
      spawned[1].on_exit({ code = 0, stdout = PNG })
      ok(attached_said(t5.id), "the image is attached once it is there: " .. said())
      eq(#shots_of(t5.id), 1, "one screenshot in assets/screenshots/")

      -- a newer call drops an older one still waiting: nothing of the older is written
      local t6 = new_task("Clipboard twice")
      notes = {}
      from_clipboard(t6.id)
      from_clipboard(t6.id)
      eq(#spawned, 3, "both calls started the program")
      spawned[2].on_exit({ code = 0, stdout = PNG })
      spawned[3].on_exit({ code = 0, stdout = PNG })
      ok(attached_said(t6.id), "the newer call attaches")
      vim.wait(50, function()
        return false
      end)
      eq(#shots_of(t6.id), 1, "the older call attached nothing")
      eq(select(2, said():gsub("attached " .. t6.id:gsub("%p", "%%%0"), "")), 1, "said once")

      -- the token belongs to the task: a call for another task meanwhile drops nothing
      local t8 = new_task("Clipboard first task")
      local t9 = new_task("Clipboard second task")
      notes = {}
      from_clipboard(t8.id)
      from_clipboard(t9.id)
      eq(#spawned, 5, "one program per call")
      spawned[4].on_exit({ code = 0, stdout = PNG })
      spawned[5].on_exit({ code = 0, stdout = PNG })
      ok(attached_said(t8.id) and attached_said(t9.id), "both tasks get their image: " .. said())
      eq(#shots_of(t8.id) + #shots_of(t9.id), 2, "one screenshot each")

      -- an empty clipboard is said, later
      notes = {}
      from_clipboard(t6.id)
      spawned[6].on_exit({ code = 1, stdout = "" })
      vim.wait(1000, function()
        return said():find("no image", 1, true) ~= nil
      end, 5)
      has(said(), "no image in the clipboard", "an empty clipboard says so")

      -- an older lib.nvim without save_async: `save`, which waits (here for its replaced runner)
      package.loaded["lib.nvim.clipboard_image"] = { save = real_clip.save }
      cmd.attach_opts.clipboard.system = function()
        return { code = 0, stdout = PNG }
      end
      local t7 = new_task("Clipboard old lib")
      notes = {}
      from_clipboard(t7.id)
      package.loaded["lib.nvim.clipboard_image"] = real_clip
      has(said(), "attached " .. t7.id, "an older lib.nvim still attaches (at once)")
    end)
    vim.system = real_system
    package.loaded["lib.nvim.clipboard_image"] = real_clip
    cmd.attach_opts = nil
    ok(sys_ok, tostring(sys_err))

    -- ── no clipboard image: the newest screenshot ──
    local shots = H.tmpdir() .. "/shots"
    vim.fn.mkdir(shots, "p")
    local shot = shots .. "/Screenshot 1.png"
    local fh = assert(io.open(shot, "wb"))
    fh:write(PNG)
    fh:close()
    vim.uv.fs_utime(shot, NOW - 30, NOW - 30)
    local t2 = new_task("From a screenshot")
    notes = {}
    seam("", shots)
    local res2 = cmd.attach_screenshot(t2.id)
    ok(res2, "with nothing on the clipboard the newest screenshot is attached")
    eq(
      res2.source ~= nil and res2.source:find("clipboard", 1, true) == nil,
      true,
      "...and says where it came from"
    )

    -- ── neither: one message, nothing attached, the task untouched ──
    local t3 = new_task("Nothing to attach")
    local before = H.read(scan.find(t3.id, { root = root }).path)
    notes = {}
    seam("")
    eq(cmd.attach_screenshot(t3.id), nil, "no image anywhere: nothing is attached")
    local after = scan.find(t3.id, { root = root })
    eq(H.read(after.path), before, "the task file is as it was")
    eq(vim.uv.fs_stat(vim.fs.dirname(after.path) .. "/assets"), nil, "no assets folder was made")
    has(said(), "no screenshot attached to " .. t3.id, "one clear message")
    ok(select(2, said():gsub("no screenshot attached", "")) == 1, "...said once")

    -- ── the form: the third answer makes the task, opens it, and attaches ──
    local function run_form(answer, title)
      local captured
      cmd.form_open = function(spec)
        captured = spec
      end
      cmd.task_new_form({})
      cmd.form_open = nil
      confirm.choose = function(_, choices, cb)
        eq(choices[3], "Yes, attach a screenshot", "the third answer is the screenshot")
        cb(answer)
      end
      captured.on_submit({ area = "lib.nvim", opts = { title = title } }, nil)
    end

    notes = {}
    seam(PNG)
    run_form(3, "Form with a shot")
    local made =
      assert(scan.find("lib.nvim/form-with-a-shot", { root = root }), "the task was created")
    ok(made.path:match("/form%-with%-a%-shot/form%-with%-a%-shot%.md$"), "as a folder task")
    local assets = vim.fn.glob(vim.fs.dirname(made.path) .. "/assets/screenshots/*", false, true)
    eq(#assets, 1, "with the screenshot in assets/screenshots/")
    -- the task is open in a window, so the link is put at its cursor (the buffer, not yet the file)
    local text, lines = "", {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == vim.fs.normalize(made.path) then
        lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        text = table.concat(lines, "\n")
      end
    end
    has(text, "![", "the link is in the new task")
    -- the new task opens with the cursor in line 1, inside the frontmatter: the link must not go there
    eq(lines[1], "---", "the frontmatter still opens with ---")
    local fm_end, link_row
    for i, l in ipairs(lines) do
      if i > 1 and not fm_end and l == "---" then
        fm_end = i
      end
      if not link_row and l:find("![", 1, true) then
        link_row = i
      end
    end
    ok(fm_end and link_row and link_row > fm_end, "the link is below the frontmatter: " .. text)
    ok(lines[link_row]:match("^!%[") ~= nil, "on a line of its own: " .. tostring(lines[link_row]))
    has(said(), "created lib.nvim/form-with-a-shot", "created")

    -- the second answer is as before: a folder, no file
    notes = {}
    run_form(2, "Form with a folder")
    local made2 = assert(scan.find("lib.nvim/form-with-a-folder", { root = root }))
    eq(#vim.fn.glob(vim.fs.dirname(made2.path) .. "/assets/*", false, true), 0, "assets/ is empty")
    lacks(said(), "attached", "nothing was attached")

    -- the first answer: a plain task
    run_form(1, "Plain form task")
    local plain = assert(scan.find("lib.nvim/plain-form-task", { root = root }))
    ok(
      plain.path:match("/plain%-form%-task%.md$") and not plain.path:match("/plain%-form%-task/"),
      "no folder"
    )

    -- no image for the third answer: the task is made, the message says nothing was attached
    notes = {}
    seam("")
    run_form(3, "Form without a shot")
    local bare =
      assert(scan.find("lib.nvim/form-without-a-shot", { root = root }), "the task is made anyway")
    eq(
      #vim.fn.glob(vim.fs.dirname(bare.path) .. "/assets/*", false, true),
      0,
      "but nothing was attached"
    )
    has(said(), "no screenshot attached to lib.nvim/form-without-a-shot", "and the message says so")

    -- ── the dashboard ──
    local keys = require("tasks_nvim.config").get().keys
    ok(
      keys.dashboard.attach and keys.dashboard_input.attach,
      "the dashboard has an attach key (list and input)"
    )
    local help = table.concat(dash.help_lines(), "\n")
    has(help, "attach a screenshot", "the help lists it")
    has(help, keys.dashboard.attach, "...with its key")

    -- the plain list offers it for the chosen task
    local t4 = new_task("Dashboard shot")
    seam(PNG)
    local menus = 0
    vim.ui.select = function(items, opts, cb)
      menus = menus + 1
      if menus == 1 then
        for _, item in ipairs(items) do
          if item.id == t4.id then
            return cb(item)
          end
        end
        error("the list does not show " .. t4.id, 0)
      elseif menus == 2 then
        local labels = {}
        for _, item in ipairs(items) do
          labels[#labels + 1] = item.label
        end
        has(table.concat(labels, "|"), "attach a screenshot", "the menu offers the attach entry")
        for _, item in ipairs(items) do
          if item.label:match("^attach a screenshot") then
            return cb(item)
          end
        end
      end
      cb(nil)
    end
    dash.open({ tasks = {}, root = root, filter = {} }, { persist = false, backend = "select" })
    vim.wait(100, function()
      return false
    end)
    local dashed = assert(scan.find(t4.id, { root = root }))
    eq(
      #vim.fn.glob(vim.fs.dirname(dashed.path) .. "/assets/*", false, true),
      1,
      "the dashboard attached the shot"
    )
  end)

  vim.notify, confirm.choose, vim.ui.select = orig.notify, orig.choose, orig.select
  cmd.attach_opts, cmd.form_open, cmd.dashboard = nil, nil, nil
  vault.set_root(nil)
  pcall(vim.cmd, "silent! %bwipeout!")
  if not ok_run then
    error(err, 0)
  end
end
