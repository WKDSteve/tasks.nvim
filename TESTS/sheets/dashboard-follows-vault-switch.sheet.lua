-- Live check: an open dashboard follows `:TasksVault switch` with the real Snacks picker (task
-- tasks.nvim/dashboard-folgt-tasksvault-switch-live-mit-dem-snacks-picker; feature tasks.nvim@c57c50f).
-- The spec tasks_dash_follow_vault_spec only drives the lib.nvim kit picker; here it is snacks.nvim.
-- Two fixture vaults in a temp folder (never a real vault): `main` and `other`, two tasks each. The
-- dashboard of `main` is opened with `--prio=1` (one of its two tasks); that filter is remembered for
-- `main` only. Every live watcher handle is counted through the seam `dash.config.watch_opts.start`, so
-- a handle left on the vault the dashboard moved away from is seen.
-- snacks.nvim comes from $SNACKS_DIR, .deps/ (CI pins it), a sibling checkout or the user's lazy folder;
-- without it the sheet is a reported skip.
local FIND = [[(function()
  local cwd = vim.fn.getcwd()
  for _, d in ipairs({
    vim.env.SNACKS_DIR or "",
    cwd .. "/.deps/snacks.nvim",
    vim.fs.dirname(cwd) .. "/snacks.nvim",
    vim.env.LOCALAPPDATA and (vim.env.LOCALAPPDATA .. "/nvim-data/lazy/snacks.nvim") or "",
    vim.env.HOME and (vim.env.HOME .. "/.local/share/nvim/lazy/snacks.nvim") or "",
  }) do
    if d ~= "" and vim.fn.isdirectory(d .. "/lua/snacks/picker") == 1 then return d end
  end
end)()]]

return {
  id = "tasks.dashboard-follows-vault-switch",
  title = "tasks.nvim: the Snacks dashboard follows :TasksVault switch, with the filter of each vault",
  task = "tasks.nvim/dashboard-folgt-tasksvault-switch-live-mit-dem-snacks-picker",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  requires = {
    { lua = FIND .. " ~= nil", reason = "snacks.nvim is not installed here (set $SNACKS_DIR)" },
  },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      if vim.fn.exists("+messagesopt") == 1 then vim.o.messagesopt = "wait:0,history:500" end
      vim.opt.rtp:append(]]
        .. FIND
        .. [[)
      local H = {
        tmpdir = function()
          local d = vim.fs.normalize(vim.fn.tempname())
          vim.fn.mkdir(d, "p")
          return d
        end,
        write = function(path, text)
          vim.fn.mkdir(vim.fs.dirname(path), "p")
          local f = assert(io.open(path, "wb"))
          f:write(text)
          f:close()
        end,
      }
      local F = dofile(vim.fn.getcwd() .. "/TESTS/fixture.lua")
      _G.main, _G.other = vim.fs.normalize(F.vault(H)), vim.fs.normalize(F.vault(H))
      F.task(H, _G.main, "lib.nvim", "main-urgent", F.meta("Main urgent one", "open", { { "prio", "1" } }))
      F.task(H, _G.main, "lib.nvim", "main-later", F.meta("Main later one", "open", { { "prio", "3" } }))
      F.task(H, _G.other, "lib.nvim", "other-a", F.meta("Other first one", "open", { { "prio", "2" } }))
      F.task(H, _G.other, "lib.nvim", "other-b", F.meta("Other second one", "open", { { "prio", "3" } }))

      -- every live watcher handle, by the folder it watches
      _G.live = {}
      local dash = require("tasks_nvim.ui.dash")
      dash.config.watch = true
      dash.config.watch_opts = {
        start = function(path, on_change, opts)
          local h, err = require("lib.nvim.fs.watch").start(path, on_change, opts)
          if h then
            _G.live[h] = vim.fs.normalize(path)
            local stop = h.stop
            h.stop = function(...)
              _G.live[h] = nil
              return stop(...)
            end
          end
          return h, err
        end,
      }
      -- how many live handles watch a folder below `root`
      _G.watching = function(root)
        local n = 0
        for _, path in pairs(_G.live) do
          if path == root or path:sub(1, #root + 1) == root .. "/" then n = n + 1 end
        end
        return n
      end
      require("tasks_nvim").setup({
        vaults = { main = _G.main, other = _G.other },
        vault = "main",
        dashboard = { backend = "snacks" },
      })

      -- the open dashboard picker (snacks), if there is one
      _G.picker = function()
        local open = {}
        for _, p in ipairs(require("snacks").picker.get({ source = "tasks_nvim" })) do
          if not p.closed then open[#open + 1] = p end
        end
        return open[1], #open
      end
      _G.title = function()
        local p = _G.picker()
        return p and tostring(p.title or (p.opts and p.opts.title) or "") or ""
      end
      _G.shows = function(text)
        local p = _G.picker()
        if not p then return false end
        for _, item in ipairs(p:items()) do
          if vim.inspect(item):find(text, 1, true) then return true end
        end
        return false
      end
      _G.listed = function(n)
        local p = _G.picker()
        return p ~= nil and p:count() == n and not p.finder.task:running()
      end
      -- the filter prompts (`f` asks with vim.ui.select, which the child would cancel): answered from a queue
      _G.answers, _G.prompts = {}, {}
      vim.ui.select = function(items, opts, on_choice)
        table.insert(_G.prompts, opts and opts.prompt or "")
        local want = table.remove(_G.answers, 1)
        for _, item in ipairs(items) do
          if tostring(item) == want then return on_choice(item) end
        end
        on_choice(nil)
      end]],
      note = "two fixture vaults (main, other), the watcher handles counted, tasks.nvim set up with snacks",
    },

    { keys = ":Tasks list<CR>", note = "the dashboard of main" },
    { wait = [[_G.listed(2) and _G.title():find("[main]", 1, true) ~= nil]], timeout = 30000 },
    -- a filter set in the dashboard is the one remembered for its vault (one from the command line is not: LUA-87)
    { lua = [[_G.answers = { "prio", "1" }]], note = "the answers: dimension prio, value 1" },
    { input = "<M-f>", note = "<M-f> in the prompt: set a filter chip" },
    {
      wait = [[#_G.prompts == 2 and _G.listed(1) and _G.title():find("[main]", 1, true) ~= nil]],
      timeout = 30000,
      note = "asked twice, the dashboard of main shows prio 1 only",
    },
    {
      expect = [[_G.shows("Main urgent one") and not _G.shows("Main later one")]],
      note = "the filter holds",
    },
    {
      wait = [[_G.watching(_G.main) > 0]],
      timeout = 30000,
      note = "the live refresh watches main",
    },

    { keys = ":TasksVault switch other<CR>", note = "switch to the other vault" },
    {
      wait = [[_G.listed(2) and _G.title():find("[other]", 1, true) ~= nil]],
      timeout = 30000,
      note = "the dashboard opened again on other, its title names it",
    },
    {
      expect = [[_G.shows("Other first one") and _G.shows("Other second one")]],
      note = "the tasks of other",
    },
    { expect = [[select(2, _G.picker()) == 1]], note = "one dashboard, the old picker is closed" },
    {
      wait = [[_G.watching(_G.main) == 0 and _G.watching(_G.other) > 0]],
      timeout = 30000,
      note = "no handle left on main",
    },

    { keys = ":TasksVault switch main<CR>", note = "back to main" },
    {
      wait = [[_G.listed(1) and _G.title():find("[main]", 1, true) ~= nil]],
      timeout = 30000,
      note = "on main again, with the filter remembered for main (prio 1: one of two tasks)",
    },
    { expect = [[_G.shows("Main urgent one")]] },
    { expect = [[select(2, _G.picker()) == 1]], note = "still one dashboard" },
    {
      wait = [[_G.watching(_G.other) == 0 and _G.watching(_G.main) > 0]],
      timeout = 30000,
      note = "no handle left on other",
    },

    {
      expect = [[vim.v.errmsg == "" and not vim.fn.execute("messages"):find("rror", 1, true)]],
      note = "no error in v:errmsg or :messages",
    },
    { lua = [[local p = _G.picker(); if p then p:close() end]], note = "close the dashboard" },
    {
      wait = [[_G.picker() == nil and _G.watching(_G.main) == 0]],
      timeout = 30000,
      note = "closed, no watcher left at all",
    },
  },
  judge = {},
  manual = {
    "With the real config and the real vaults (main and tricentis): :TasksVault switch tricentis reopens the dashboard, title [tricentis]",
  },
}
