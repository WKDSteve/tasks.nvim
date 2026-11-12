---@module 'tasks_nvim.health'
---@brief `:checkhealth tasks_nvim` diagnostics.
---@description
--- Read-only: reports what the engine needs (Neovim, lib.nvim submodules, a vault), what the optional front-end
--- pieces need (snacks.nvim for the dashboard, git for `--stale=refs`) and which soft dependencies are present.
--- Nothing is created or changed.

local M = {}

---@return nil
function M.check()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local error_ = health.error or health.report_error
  local info = health.info or health.report_info

  start("tasks.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    error_("tasks.nvim needs Neovim 0.11+", { "Upgrade Neovim to 0.11+" })
  end

  -- lib.nvim is a hard dependency; these are the submodules the engine and the front ends call.
  local required = {
    {
      "lib.nvim.markdown.frontmatter",
      "task files are read and written through it",
      function()
        return require("lib.nvim.markdown.frontmatter")
      end,
    },
    {
      "lib.nvim.fs.collect_recursive",
      "the vault scan",
      function()
        return require("lib.nvim.fs.collect_recursive")
      end,
    },
    {
      "lib.nvim.checkpoint",
      "`done` rolls back from it",
      function()
        return require("lib.nvim.checkpoint")
      end,
    },
    {
      "lib.nvim.bindings.usercmd.composer",
      "the :Tasks command",
      function()
        return require("lib.nvim.bindings.usercmd.composer")
      end,
    },
    {
      "lib.nvim.harvest",
      "delivery of lists (--to=)",
      function()
        return require("lib.nvim.harvest")
      end,
    },
    {
      "lib.nvim.notify",
      "messages",
      function()
        return require("lib.nvim.notify")
      end,
    },
    {
      "lib.nvim.fs.read",
      "file reads",
      function()
        return require("lib.nvim.fs.read")
      end,
    },
    {
      "lib.nvim.fs.mkdirp",
      "creating folders",
      function()
        return require("lib.nvim.fs.mkdirp")
      end,
    },
    {
      "lib.nvim.fs.scan_cached",
      "the cached vault scan (completion)",
      function()
        return require("lib.nvim.fs.scan_cached")
      end,
    },
    {
      "lib.nvim.cross.fs.mutate",
      "moving and removing files",
      function()
        return require("lib.nvim.cross.fs.mutate")
      end,
    },
    {
      "lib.nvim.ui.list",
      "quickfix delivery (--to=qf)",
      function()
        return require("lib.nvim.ui.list")
      end,
    },
    {
      "lib.nvim.harvest.render",
      "Markdown and CSV tables",
      function()
        return require("lib.nvim.harvest.render")
      end,
    },
    {
      "lib.nvim.cross.fs.expand_path",
      "`--to=file:` paths",
      function()
        return require("lib.nvim.cross.fs.expand_path")
      end,
    },
    {
      "lib.nvim.cross.fs.separators.unify_slashes",
      "path normalisation",
      function()
        return require("lib.nvim.cross.fs.separators.unify_slashes")
      end,
    },
    {
      "lib.nvim.cross.platform.is_windows",
      "platform checks",
      function()
        return require("lib.nvim.cross.platform.is_windows")
      end,
    },
    {
      "lib.nvim.system.env",
      "the repos folder for `--stale=refs`",
      function()
        return require("lib.nvim.system.env")
      end,
    },
  }
  local lib_ok = true
  for _, req in ipairs(required) do
    if pcall(req[3]) then
      ok(("%s -- %s"):format(req[1], req[2]))
    else
      lib_ok = false
      error_(
        ("%s missing -- %s"):format(req[1], req[2]),
        { 'Install or update "WKDSteve/lib.nvim"' }
      )
    end
  end
  if not lib_ok then
    return
  end

  start("tasks.nvim: vault")
  local vault = require("tasks_nvim.vault")
  local root, err = vault.root()
  if not root then
    warn(tostring(err), { "setup({ vault = <dir> }) or set $TASKS_VAULT" })
  else
    local areas = vault.areas(root)
    local active = vault.active_name()
    ok(("vault %s%s: %d area(s)"):format(active and (active .. " = ") or "", root, #areas))
    local names = vault.vault_names()
    if #names > 1 then
      info("named vaults: " .. table.concat(names, ", ") .. " (:TasksVault switch <name>)")
    end
    local marker = require("tasks_nvim.vault_marker").status(root)
    if marker.layout_version then
      ok(("marker file tasks-vault.json: layout version %d"):format(marker.layout_version))
    else
      info(
        "no tasks-vault.json (optional: the layout version, extra areas and defaults of the vault)"
      )
    end
    local extras = vault.extra_areas(root)
    if #extras > 0 then
      info("extra areas: " .. table.concat(extras, ", "))
    end
  end

  local ignored = require("tasks_nvim.config").ignored()
  for _, msg in ipairs(ignored) do
    warn("setup() ignored an option: " .. msg)
  end
  if #ignored == 0 then
    ok("setup() options are valid")
  end

  -- Named lists: what each source contributes, and every list that had to be skipped (named, with the reason).
  local lists = require("tasks_nvim.lists")
  local entries, list_notes = lists.all()
  local by_source = { builtin = 0, saved = 0, config = 0 }
  for _, e in ipairs(entries) do
    by_source[e.source] = by_source[e.source] + 1
  end
  info(
    ("named lists: %d (built in as shown: %d, saved: %d, setup(): %d); saved lists file: %s"):format(
      #entries,
      by_source.builtin,
      by_source.saved,
      by_source.config,
      lists.path()
    )
  )
  for _, msg in ipairs(list_notes) do
    warn(msg)
  end

  start("tasks.nvim: command")
  if vim.fn.exists(":Tasks") == 2 then
    ok(":Tasks is registered")
  elseif vim.g.tasks_nvim_no_command then
    info(":Tasks is not registered (vim.g.tasks_nvim_no_command is set)")
  else
    warn(":Tasks is not registered", {
      "call require('tasks_nvim').setup({ ... }) or load the plugin on `cmd = { 'Tasks', 'TasksVault' }`",
    })
  end

  start("tasks.nvim: optional pieces")
  if pcall(require, "snacks") then
    ok("snacks.nvim -- the interactive dashboard")
  else
    info("snacks.nvim not found -- the dashboard falls back to a plain vim.ui.select list")
  end
  if vim.fn.executable("git") == 1 then
    ok("git -- `--stale=refs` dates files by their last commit")
  else
    info("git not found -- `--stale=refs` uses file modification times")
  end
  -- `attach` without a file: the tool that reads the clipboard image, and the folders the newest screenshot is looked for in
  local clip_ok, clip = pcall(require, "lib.nvim.clipboard_image")
  if clip_ok and type(clip.tool) == "function" then
    local tool, why = clip.tool()
    if tool then
      ok(("%s -- `attach --clipboard` reads the clipboard image"):format(tool))
    else
      info(("no clipboard image tool -- `attach --clipboard` is not available (%s)"):format(why))
    end
  else
    info("lib.nvim.clipboard_image not found -- `attach --clipboard` is not available")
  end
  local dirs = require("tasks_nvim.attach_source").screenshot_dirs()
  local found = vim.tbl_filter(function(dir)
    return vim.fn.isdirectory(vim.fn.expand(dir)) == 1
  end, dirs)
  if #found > 0 then
    ok("screenshot folders for `attach --latest`: " .. table.concat(found, ", "))
  else
    info(
      "no screenshot folder exists ("
        .. table.concat(dirs, ", ")
        .. ") -- set `attach.screenshot_dirs`"
    )
  end
  if pcall(require, "mdview") then
    ok("mdview.nvim -- browser preview (`:Tasks preview`, `--to=mdview`)")
  else
    info("mdview.nvim not found -- no browser preview")
  end
  local dialog_ok, dialog = pcall(require, "lib.nvim.ui.dialog")
  if dialog_ok and type(dialog) == "table" and dialog.confirm then
    local backend = type(dialog.backend) == "function" and dialog.backend() or "?"
    local load_errors = type(dialog.load_errors) == "function" and dialog.load_errors() or {}
    for name, load_err in pairs(load_errors) do
      warn(("%s is installed but failed to load: %s"):format(name, load_err))
    end
    if backend == "native" then
      info("confirmations use vim.ui.select (no kit loads: ui.nvim and lib.nvim's ui.kit)")
    else
      ok("confirmations use the dialog of " .. backend)
    end
  else
    warn("this lib.nvim has no ui.dialog -- confirmations use vim.ui.select; update lib.nvim")
  end
  if pcall(require, "cascade") then
    ok("cascade.nvim -- cycling values in the task form")
  else
    info("cascade.nvim not found -- the form has no value cycling")
  end
  if pcall(require, "pickers.command") then
    ok("pickers.nvim -- `:Tasks folder`")
  else
    info("pickers.nvim not found -- `:Tasks folder` uses a plain vim.ui.select list")
  end
  local soft = {
    {
      "lib.nvim.progress",
      "a progress entry while the dashboard writes",
      function()
        return require("lib.nvim.progress")
      end,
    },
    {
      "lib.nvim.store.project",
      "remembering the dashboard filter and sort",
      function()
        return require("lib.nvim.store.project")
      end,
    },
    {
      "lib.nvim.fs.watch",
      "live refresh of the dashboard",
      function()
        return require("lib.nvim.fs.watch")
      end,
    },
  }
  for _, req in ipairs(soft) do
    if pcall(req[3]) then
      ok(("%s -- %s"):format(req[1], req[2]))
    else
      info(("%s not found (older lib.nvim?) -- no %s"):format(req[1], req[2]))
    end
  end
end

return M
