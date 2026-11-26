-- Live check of `:Tasks checklist` (task tasks.nvim/checklisten-in-neovim-befehl-zum-anzeigen-eintragen-und): typed in a
-- real editor, so the command line, the routes, the real `vim.ui.input` prompt (typed into), the buffer-local keys and
-- the write door are checked together. The spec checks the handlers alone (tasks_checklist_view_spec). A fixture vault
-- in a temp folder (never a real vault). The picker of the lists and of the areas is recorded and answers with its
-- first item; how the real picker looks is left to a person (`manual`).
return {
  id = "tasks.checklist-commands",
  title = "tasks.nvim: :Tasks checklist new, add, the list buffer (add, tick, state, filter, open as a file) and the picker",
  feature = "tasks.checklist",
  task = "tasks.nvim/checklisten-in-neovim-befehl-zum-anzeigen-eintragen-und",
  engine = "rpc",
  -- `vim.ui.input` (the built-in `input()`) asks for real: `a` and `f` are typed into the command line
  prompts = "real",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      if vim.fn.exists("+messagesopt") == 1 then vim.o.messagesopt = "wait:0,history:500" end
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
      _G.root = vim.fs.normalize(F.vault(H))
      require("tasks_nvim").setup({ vault = _G.root })
      _G.picked = {}
      vim.ui.select = function(items, opts, on_choice)
        local fmt = opts.format_item or tostring
        table.insert(_G.picked, { items = items, label = fmt(items[1]) })
        on_choice(items[1])
      end
      _G.line = function(n)
        return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1] or ""
      end
      _G.lines = function()
        return #vim.api.nvim_buf_get_lines(0, 0, -1, false)
      end
      _G.entries = function()
        return require("tasks_nvim.checklist").entries(_G.root, "_list-einkauf")
      end]],
      note = "a fixture vault; the pickers recorded",
    },

    { keys = ":Tasks checklist new Einkauf<CR>" },
    {
      expect = [[vim.api.nvim_buf_get_name(0):find("tasks-checklist://_list-einkauf", 1, true) ~= nil and _G.line(1):find("Einkauf", 1, true) == 1]],
      note = "the list is made and shown in a buffer of its own",
    },

    { keys = ":Tasks checklist add einkauf Brot #baecker<CR>" },
    {
      expect = [[_G.line(4):find("Brot  #baecker", 1, true) ~= nil]],
      note = "add by slug: the #word is a tag, the shown list is drawn again",
    },

    -- a: the real input prompt of the command line, typed into
    -- queued: the prompt of `a` (a blocking `input()`, no Lua call is answered meanwhile) takes the rest of the keys
    { input = "aMilch #laden<CR>" },
    {
      wait = [[#_G.entries() == 2 and _G.line(4):find("Milch  #laden", 1, true) ~= nil]],
      note = "the new entry is first",
    },

    { keys = "x" },
    {
      expect = [[_G.line(4):sub(1, 3) == "[x]" and _G.line(1):find("1 open of 2", 1, true) ~= nil]],
      note = "x ticks the entry under the cursor; the title line counts it",
    },

    { keys = "s" },
    {
      expect = [[_G.line(2):find("state:open", 1, true) ~= nil and _G.line(4):find("Brot", 1, true) ~= nil and _G.lines() == 4]],
      note = "s shows the open ones only",
    },
    { keys = "F" },

    { input = "f#laden<CR>" },
    {
      wait = [[_G.line(2):find("#laden", 1, true) ~= nil and _G.line(4):find("Milch", 1, true) ~= nil and _G.lines() == 4]],
      note = "f filters by tag (the real prompt)",
    },
    { keys = "F" },
    { expect = [[_G.lines() == 5]], note = "F clears the filter" },

    { keys = "j<CR>" },
    {
      expect = [[vim.bo.filetype == "markdown" and vim.api.nvim_buf_get_name(0):find("_list-einkauf", 1, true) ~= nil and vim.api.nvim_get_current_line() == "---"]],
      note = "<CR> opens the entry as a Markdown file",
    },

    { keys = ":enew<CR>" },
    { keys = ":Tasks checklist<CR>" },
    {
      expect = [[#_G.picked == 1 and _G.picked[1].label:find("Einkauf  (1 open of 2)", 1, true) ~= nil and _G.line(1):find("Einkauf", 1, true) == 1]],
      note = "the picker names title and counts; the list picked is shown",
    },

    { keys = "g?" },
    {
      expect = [[(function() for _, w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).relative ~= "" then return true end end return false end)()]],
      note = "g? shows the keys in a float",
    },
    { keys = "<Esc>" },

    { keys = "q" },
    {
      expect = [[not vim.api.nvim_buf_get_name(0):find("tasks-checklist://", 1, true)]],
      note = "q closes the list",
    },

    {
      expect = [[vim.v.errmsg == "" and not vim.fn.execute("messages"):find("rror", 1, true)]],
      note = "no error in v:errmsg or :messages",
    },
  },
  judge = {},
  manual = {
    ":Tasks checklist shows the real picker (snacks or the built-in select): one line per list with title, open of all and id",
    "in a list buffer: a ticked entry is dimmed, days and tags have their own colour, the cursor stays on the entry after x",
    "T in a list buffer: the real area picker, then the entry is gone and the message names the new task",
    "D asks in the themed dialog of lib.nvim (No first), then the entry is gone",
  },
}
