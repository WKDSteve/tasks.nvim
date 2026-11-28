-- TESTS/tasks_fixture_isolation_spec.lua -- a fixture vault is blind to the tasks-desktop of the machine: on a
-- machine that runs it (a live `hub.json`), `:Tasks new` in a spec asked "Open … in tasks-desktop?" and the guard of
-- the runner failed the spec on a prompt nobody answered (`tasks_command_spec`, `tasks_review2_spec` on STEVESPC).

return function(H)
  local eq = H.eq
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local app = require("tasks_nvim.open_app")

  -- the machine: a running tasks-desktop (a hub.json of a live process, this one)
  local machine = H.tmpdir() .. "/machine-tasks-desktop"
  vim.fn.mkdir(machine, "p")
  H.write(
    machine .. "/hub.json",
    vim.json.encode({
      app = "tasks-desktop",
      port = 4711,
      pid = vim.uv.os_getpid(),
      version = "0",
      instance = "ab",
    })
  )
  local saved = { cfg = vim.env.TASKS_DESKTOP_CONFIG_DIR, role = vim.env.NVIM_MACHINE_ROLE }
  vim.env.TASKS_DESKTOP_CONFIG_DIR = machine
  vim.env.NVIM_MACHINE_ROLE = ""
  eq(app.available(), "desktop", "the hub of the machine is seen before the fixture")

  F.vault(H)
  eq(app.available(), nil, "a fixture vault does not see the tasks-desktop of the machine")
  local said = {}
  -- no asker: a prompt here would be `vim.fn.confirm`, which the guard of the runner fails
  app.after_new("lib.nvim/alpha", function(msg)
    said[#said + 1] = msg
  end)
  eq(said, {}, "nothing was asked or opened")

  vim.env.TASKS_DESKTOP_CONFIG_DIR, vim.env.NVIM_MACHINE_ROLE = saved.cfg, saved.role
end
