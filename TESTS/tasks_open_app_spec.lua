-- TESTS/tasks_open_app_spec.lua -- `:Tasks open <id> --desktop | --web` and the question after `:'<,'>Tasks new`:
-- the address, the port from the hub.json of tasks-desktop, the workstation rule and the option `new.open_after`.
-- The system opener and the question are stubbed: nothing is opened.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has

  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local vault = require("tasks_nvim.vault")
  local mutate = require("tasks_nvim.mutate")
  local config = require("tasks_nvim.config")
  local app = require("tasks_nvim.open_app")
  local cmd = require("tasks_nvim.ui.cmd")

  -- The option: ask by default; always, never and ask pass; another word is dropped. `open.web_dir` is a string.
  eq(require("tasks_nvim.config.DEFAULTS").new.open_after, "ask", "the default is ask")
  eq(config.validate({ new = { open_after = "always" } }).new.open_after, "always", "always passes")
  eq(config.validate({ new = { open_after = "never" } }).new.open_after, "never", "never passes")
  eq(
    (config.validate({ new = { open_after = "sometimes" } }).new or {}).open_after,
    nil,
    "another word is dropped"
  )
  eq(
    (config.validate({ open = { web_dir = 5 } }).open or {}).web_dir,
    nil,
    "web_dir must be a string"
  )

  -- The address: the id goes through encodeURIComponent, like route.ts of the page.
  eq(app.fragment("lib.nvim/alpha-widget"), "#task=lib.nvim%2Falpha-widget", "the slash is escaped")
  eq(
    app.desktop_url(17615, "a/b"),
    "http://127.0.0.1:17615/#task=a%2Fb",
    "the loopback address with the port"
  )
  eq(app.id_of_path("C:/v/lib.nvim/ROADMAP/tasks/x-y.md"), "lib.nvim/x-y", "a task file is its id")
  eq(app.id_of_path("C:/v/lib.nvim/ROADMAP/tasks/x-y/x-y.md"), "lib.nvim/x-y", "a folder task too")
  eq(app.id_of_path("C:/v/lib.nvim/README.md"), nil, "another file is none")

  local root = F.vault(H)
  vault.set_root(root)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Alpha Widget" })))

  local saved = {
    cfg = vim.env.TASKS_DESKTOP_CONFIG_DIR,
    role = vim.env.NVIM_MACHINE_ROLE,
    notify = vim.notify,
  }
  local before = vim.deepcopy(config.get())
  local desktop = H.tmpdir() .. "/tasks-desktop-config"
  local web = H.tmpdir() .. "/tasks-web"
  vim.fn.mkdir(desktop, "p")
  vim.fn.mkdir(web, "p")
  vim.env.TASKS_DESKTOP_CONFIG_DIR = desktop
  vim.env.NVIM_MACHINE_ROLE = ""
  local function hub(app_name, port)
    local f = assert(io.open(desktop .. "/hub.json", "wb"))
    f:write(vim.json.encode({
      app = app_name,
      port = port,
      pid = vim.uv.os_getpid(),
      version = "0",
      instance = "ab",
    }))
    f:close()
  end

  local opened, notes, asked, answer = {}, {}, {}, true
  app.opener = function(url)
    opened[#opened + 1] = url
    return true, nil
  end
  app.asker = function(prompt)
    asked[#asked + 1] = prompt
    return answer
  end
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  ---@param flags table
  ---@param id string|nil
  local function run(flags, id)
    opened, notes = {}, {}
    cmd.task_open({ args = { id = id }, flags = flags, kv = {}, rest = {} })
  end

  local done, err = pcall(function()
    -- --desktop without a hub: told, nothing opened, --web named.
    run({ desktop = true }, "lib.nvim/alpha-widget")
    eq(opened, {}, "no hub.json: nothing opened")
    has(notes[1].msg, "not running")
    has(notes[1].msg, "--web")

    -- a hub.json of another app is not tasks-desktop's
    hub("ai-desktop", 8080)
    run({ desktop = true }, "lib.nvim/alpha-widget")
    eq(opened, {}, "the hub of another app is ignored")

    hub("tasks-desktop", 17615)
    run({ desktop = true }, "lib.nvim/alpha-widget")
    eq(
      opened,
      { "http://127.0.0.1:17615/#task=lib.nvim%2Falpha-widget" },
      "the port comes from hub.json"
    )

    -- an id that is no task is told, nothing opened
    run({ desktop = true }, "lib.nvim/nope")
    eq(opened, {}, "no such task: nothing opened")

    -- without an id: the task of the buffer
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/lib.nvim/ROADMAP/tasks/alpha-widget.md"))
    run({ desktop = true }, nil)
    eq(#opened, 1, "no id: the task of the buffer")
    has(opened[1], "#task=lib.nvim%2Falpha-widget")
    vim.cmd("enew")

    -- the workstation: only --web (MASCHINE-04)
    vim.env.NVIM_MACHINE_ROLE = "Workstation"
    run({ desktop = true }, "lib.nvim/alpha-widget")
    eq(opened, {}, "on the workstation --desktop opens nothing")
    has(notes[1].msg, "workstation")
    vim.env.NVIM_MACHINE_ROLE = ""

    -- --web: not set up, a folder without tasks.html, then a good one
    config.merge({})
    run({ web = true }, "lib.nvim/alpha-widget")
    eq(opened, {}, "web_dir not set: nothing opened")
    has(notes[1].msg, "web_dir")
    config.merge({ open = { web_dir = web } })
    run({ web = true }, "lib.nvim/alpha-widget")
    eq(opened, {}, "no tasks.html there: nothing opened")
    vim.fn.writefile({ "<html>" }, web .. "/tasks.html")
    run({ web = true }, "lib.nvim/alpha-widget")
    eq(#opened, 1)
    ok(opened[1]:match("^file://") ~= nil, "a file address")
    ok(
      opened[1]:match("/tasks%-web/tasks%.html#task=lib%.nvim%%2Falpha%-widget$") ~= nil,
      opened[1]
    )

    run({ web = true, desktop = true }, "lib.nvim/alpha-widget")
    eq(opened, {}, "both flags exclude each other")

    -- after a new task from a selection
    local function after(mode)
      config.merge({ new = { open_after = mode }, open = { web_dir = web } })
      opened, asked, notes = {}, {}, {}
      app.after_new("lib.nvim/alpha-widget", function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
      end)
    end
    after("ask")
    eq(#asked, 1, "ask: one question")
    has(asked[1], "lib.nvim/alpha-widget")
    eq(#opened, 1, "yes opens it (tasks-desktop runs)")
    has(opened[1], "127.0.0.1:17615")
    answer = false
    after("ask")
    eq(opened, {}, "no opens nothing")
    answer = true
    after("always")
    eq(asked, {}, "always: no question")
    eq(#opened, 1, "always opens")
    after("never")
    eq(asked, {}, "never: no question")
    eq(opened, {}, "never opens nothing")
    eq(app.last_created, "lib.nvim/alpha-widget", "the last created task is remembered")

    -- neither a running tasks-desktop nor a tasks-web: nothing is asked
    os.remove(desktop .. "/hub.json")
    config.merge({ new = { open_after = "ask" } })
    opened, asked = {}, {}
    app.after_new("lib.nvim/alpha-widget", function() end)
    eq(asked, {}, "nothing to open in: no question")
    eq(opened, {}, "and nothing opened")

    -- the workstation is offered tasks-web only
    hub("tasks-desktop", 17615)
    config.merge({ new = { open_after = "always" }, open = { web_dir = web } })
    vim.env.NVIM_MACHINE_ROLE = "workstation"
    opened = {}
    app.after_new("lib.nvim/alpha-widget", function() end)
    eq(#opened, 1)
    ok(opened[1]:match("^file://") ~= nil, "on the workstation the web page opens, not the hub")

    -- :'<,'>Tasks new <area> from a selection asks, a plain `Tasks new <area> title` does not
    vim.env.NVIM_MACHINE_ROLE = ""
    config.merge({ new = { open_after = "ask" } })
    local file = H.tmpdir() .. "/code.lua"
    vim.fn.writefile({ "local x = 1", "local y = 2" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    opened, asked = {}, {}
    cmd.task_new({
      args = { area = "lib.nvim" },
      kv = {},
      flags = {},
      rest = { "Made", "from", "code" },
      range = { range = 1, line1 = 1, line2 = 2 },
    })
    eq(#asked, 1, "a task from a selection asks")
    eq(#opened, 1, "and opens it on yes")
    has(opened[1], "made-from-code")
    vim.cmd("enew")
    opened, asked = {}, {}
    cmd.task_new({
      args = { area = "lib.nvim" },
      kv = {},
      flags = {},
      rest = { "Plain", "one" },
      range = { range = 0, line1 = 1, line2 = 1 },
    })
    eq(asked, {}, "a task without a selection does not ask")

    -- the form of a selection (no area) asks after its submit
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    opened, asked = {}, {}
    local captured
    cmd.form_open = function(spec)
      captured = spec
    end
    cmd.task_new({
      args = { area = nil },
      kv = {},
      flags = {},
      rest = {},
      range = { range = 1, line1 = 1, line2 = 2 },
    })
    cmd.form_open = nil
    assert(captured, "the form opened")
    local confirm = require("tasks_nvim.ui.confirm")
    local orig_choose = confirm.choose
    confirm.choose = function(_, _, cb)
      cb(1)
    end
    captured.on_submit({ area = "lib.nvim", opts = { title = "Via form selection" } }, nil)
    confirm.choose = orig_choose
    eq(#asked, 1, "the form of a selection asks")
    has(opened[1], "via-form-selection")
    vim.cmd("enew")
  end)

  app.opener, app.asker, app.last_created = nil, nil, nil
  vim.notify = saved.notify
  vim.env.TASKS_DESKTOP_CONFIG_DIR = saved.cfg
  vim.env.NVIM_MACHINE_ROLE = saved.role
  config.merge(before)
  vault.set_root(nil)
  if not done then
    error(err, 0)
  end
end
