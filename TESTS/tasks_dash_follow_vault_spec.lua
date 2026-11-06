-- TESTS/tasks_dash_follow_vault_spec.lua -- an open dashboard follows `:TasksVault switch`, and its title names the
-- vault once several are configured. Uses the lib.nvim kit picker (no snacks needed); two fixture vaults.

---@diagnostic disable: need-check-nil, duplicate-set-field

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local vault = require("tasks_nvim.vault")
  local config = require("tasks_nvim.config")
  local dash = require("tasks_nvim.ui.dash")

  local main, second = F.vault(H), F.vault(H)
  local saved_env = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = nil
  local watch_was = dash.config.watch
  dash.config.watch = false

  -- ── name_of: only configured vaults have a name ────────────────────────────
  vault.configure(config.merge({ vaults = { main = main, other = second }, vault = "main" }))
  eq(vault.name_of(main), "main")
  eq(vault.name_of(second .. "/"), "other", "trailing slash does not matter")
  eq(vault.name_of(main .. "/nope"), nil)
  eq(vault.name_of(""), nil)

  -- ── an open dashboard moves to the new vault ───────────────────────────────
  local state = dash.open(
    { tasks = {}, filter = {}, root = vault.root() },
    { backend = "kit", persist = false }
  )
  if state and state.close then
    eq(state.root, vim.fs.normalize(main))
    eq(dash.follow_vault(vim.fs.normalize(main)), 0, "a dashboard on that vault stays")
    eq(dash.follow_vault(vim.fs.normalize(second)), 1, "one open dashboard moved")
    eq(state.close, nil, "the old picker was closed")
    eq(
      dash.follow_vault(vim.fs.normalize(second)),
      0,
      "now it is on the right vault; nothing to move"
    )
    -- the moved dashboard can be moved on again
    eq(dash.follow_vault(vim.fs.normalize(main)), 1)
    eq(dash.follow_vault(vim.fs.normalize(main)), 0)
  else
    io.stdout:write(
      "skip  tasks_dash_follow_vault_spec.lua: the kit picker did not open headless\n"
    )
  end
  -- close what is left
  for _ = 1, 2 do
    dash.follow_vault("__nowhere__")
  end
  pcall(vim.cmd, "silent! %bwipeout!")

  -- ── leave the process as the other specs expect ────────────────────────────
  dash.config.watch = watch_was
  vault.configure({ vaults = {} })
  vault.configure(config.merge({ vault = main }))
  vim.env.TASKS_VAULT = saved_env
  vault.set_root(nil)
  ok(true)
end
