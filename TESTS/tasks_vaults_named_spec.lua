-- TESTS/tasks_vaults_named_spec.lua -- several named vaults: setup({ vaults, vault }), switch, config validation,
-- and the `:TasksVault switch` handler (two fixture vaults that both hold an area called lib.nvim).

---@diagnostic disable: need-check-nil

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local vault = require("tasks_nvim.vault")
  local config = require("tasks_nvim.config")

  local main, second = F.vault(H), F.vault(H)
  ok(main ~= second, "the fixtures are two folders")

  local saved_env = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = nil
  vault.set_root(nil)

  -- ── a name in `vault` picks that vault ─────────────────────────────────────
  vault.configure(config.merge({ vaults = { main = main, other = second }, vault = "other" }))
  eq(vault.active_name(), "other")
  eq(select(1, vault.root()), vim.fs.normalize(second))
  eq(vault.vault_names(), { "main", "other" }, "names are sorted")

  -- ── `vault` as a path stays valid and names nothing ────────────────────────
  vault.configure(config.merge({ vaults = { main = main }, vault = second }))
  eq(vault.active_name(), nil, "a path is no name")
  eq(select(1, vault.root()), vim.fs.normalize(second))

  -- ── without `vault` the first name (sorted) is active ──────────────────────
  vault.configure(config.merge({ vaults = { zeta = second, alpha = main } }))
  eq(vault.active_name(), "alpha")
  eq(select(1, vault.root()), vim.fs.normalize(main))

  -- ── switch ─────────────────────────────────────────────────────────────────
  local root, err = vault.switch("zeta")
  eq(err, nil)
  eq(root, vim.fs.normalize(second))
  eq(vault.active_name(), "zeta")
  eq(select(1, vault.root()), vim.fs.normalize(second), "root follows the switch")

  local none, why = vault.switch("nope")
  eq(none, nil)
  ok(why:find("unknown vault 'nope'", 1, true) and why:find("alpha, zeta", 1, true), why)
  eq(vault.active_name(), "zeta", "a failed switch changes nothing")

  -- a named folder that is gone: refused, the active vault stays
  vault.configure(
    config.merge({ vaults = { main = main, gone = main .. "/does-not-exist" }, vault = "main" })
  )
  local gone, gerr = vault.switch("gone")
  eq(gone, nil)
  ok(gerr:find("not a directory", 1, true), gerr)
  eq(vault.active_name(), "main")

  -- ── areas with the same name live in their own vault ───────────────────────
  local a, b = vault.area_names(main), vault.area_names(second)
  ok(
    vim.tbl_contains(a, "lib.nvim") and vim.tbl_contains(b, "lib.nvim"),
    "both vaults hold lib.nvim"
  )
  ok(
    vault.tasks_dir(main, "lib.nvim") ~= vault.tasks_dir(second, "lib.nvim"),
    "the task folders differ"
  )

  -- ── config validation ──────────────────────────────────────────────────────
  config.merge({ vaults = "x" })
  ok(
    #config.ignored() == 1 and config.ignored()[1]:find("vaults", 1, true),
    "a non-table is reported"
  )
  config.merge({ vaults = { main = 3 } })
  ok(#config.ignored() == 1, "a non-string folder is reported")
  config.merge({ vaults = { ["my vault"] = main } })
  ok(
    #config.ignored() == 1 and config.ignored()[1]:find("my vault", 1, true),
    "a name with a space is reported"
  )
  config.merge({ vaults = { main = main } })
  eq(#config.ignored(), 0)
  eq(config.get().vaults.main, vim.fs.normalize(main))

  -- a bad name or an empty path is dropped by `configure`, the rest stays
  vault.configure({ vaults = { ["bad name"] = main, ok = main, empty = "" }, vault = "ok" })
  eq(vault.vault_names(), { "ok" })

  -- a later setup() without `vaults` forgets the names (and the active name with them)
  vault.configure(config.merge({ vault = main }))
  eq(vault.vault_names(), {})
  eq(vault.active_name(), nil)

  -- ── the handler ────────────────────────────────────────────────────────────
  local notes = {}
  local notify_mod = require("lib.nvim.notify")
  local orig_create = notify_mod.create
  notify_mod.create = function()
    return {
      info = function(m)
        notes[#notes + 1] = "info:" .. m
      end,
      warn = function(m)
        notes[#notes + 1] = "warn:" .. m
      end,
    }
  end
  package.loaded["tasks_nvim.ui.vault_cmd"] = nil
  local cmd = require("tasks_nvim.ui.vault_cmd")
  vault.configure(config.merge({ vaults = { main = main, other = second }, vault = "main" }))

  cmd.switch({ args = { name = "other" } })
  ok(notes[#notes]:find("info:Vault: other = ", 1, true), notes[#notes])
  eq(vault.active_name(), "other")
  cmd.switch({ args = { name = "nope" } })
  ok(notes[#notes]:find("warn:unknown vault", 1, true), notes[#notes])
  cmd.switch({ args = {} })
  ok(notes[#notes]:find("warn::TasksVault switch <name>", 1, true), notes[#notes])

  cmd.status({ args = {} })
  ok(
    notes[#notes]:find("other = ", 1, true) and notes[#notes]:find("switch: main, other", 1, true),
    notes[#notes]
  )

  notify_mod.create = orig_create
  package.loaded["tasks_nvim.ui.vault_cmd"] = nil

  -- ── leave the process as the other specs expect ────────────────────────────
  vault.configure(config.merge({ vault = main }))
  vault.configure({ vaults = {} })
  vim.env.TASKS_VAULT = saved_env
  vault.set_root(nil)
end
