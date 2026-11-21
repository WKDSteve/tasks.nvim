-- Live check of the learning tree in the editor (task tasks.nvim/neovim-lernbaum-ansicht): `:Tasks learn`, `point`,
-- `promote` and `unpromote` typed in a real editor, so the command line, the routes, the reason question and the view
-- are checked together. The spec checks the module alone (tasks_learn_view_spec). A fixture vault in a temp folder
-- (never a real vault); the reason question (`vim.ui.input`) is answered by a stub. How an image looks in a real
-- terminal (images.nvim) is left to a person (`manual`).
return {
  id = "tasks.learning-tree",
  title = "tasks.nvim: :Tasks learn (progress, optional group, folds, image placeholder), point (marks, reason), promote and unpromote",
  feature = "tasks.learning-tree",
  task = "tasks.nvim/neovim-lernbaum-ansicht",
  engine = "rpc",
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
      _G.path_file = _G.root .. "/lib.nvim/ROADMAP/paths/lua-lernen.md"
      H.write(_G.path_file, table.concat({
        "---", "title: Lua lernen", "status: doing", "---", "",
        "## Lernpunkte", "",
        "- [ ] Lua lernen {#lua}",
        "  - [ ] Syntax {#syntax}",
        "  - [ ] ![Diagramm](assets/images/syntax.svg)",
        "  - [ ] C-Compiler {#cc}",
        "    - [ ] K&R lesen",
        "- [ ] Literatur {optional} {#lit}",
        "  - [x] Ein Buch",
        "", "## Notizen", "",
      }, "\n"))
      require("tasks_nvim").setup({ vault = _G.root, keys = { learning = { cycle = "<F5>" } } })
      _G.reason = "nur angeschaut"
      vim.ui.input = function(_, cb) cb(_G.reason) end
      _G.file_has = function(text)
        local f = io.open(_G.path_file, "rb")
        local s = f and f:read("*a") or ""
        if f then f:close() end
        return s:find(text, 1, true) ~= nil
      end
      _G.virt = function()
        local out = {}
        local ns = require("tasks_nvim.ui.learn").ns
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
          for _, c in ipairs(m[4].virt_text or {}) do out[#out + 1] = c[1] end
          for _, l in ipairs(m[4].virt_lines or {}) do
            for _, c in ipairs(l) do out[#out + 1] = c[1] end
          end
        end
        return table.concat(out, "|")
      end
      _G.line = function()
        return vim.api.nvim_get_current_line()
      end
      vim.cmd("edit " .. vim.fn.fnameescape(_G.path_file))]],
      note = "a fixture vault with a learning path; the reason question answered by a stub",
    },

    { keys = ":Tasks learn<CR>" },
    {
      expect = [[_G.virt():find("0 gelernt", 1, true) ~= nil and _G.virt():find("[image] assets/images/syntax.svg (missing)", 1, true) ~= nil]],
      note = "the progress of the tree and a placeholder for the missing image",
    },
    {
      expect = [[_G.virt():find("optional 1/1 gelernt", 1, true) ~= nil and _G.virt():find("(optional)", 1, true) ~= nil]],
      note = "the optional group apart: in the heading, and marked after the group (the learned book is not in 0 gelernt)",
    },
    {
      expect = [[vim.wo.foldmethod == "expr" and vim.fn.foldlevel(12) == 2]],
      note = "a fold per parent",
    },

    { keys = ":9<CR>" },
    { keys = "<F5>" },
    {
      expect = [[_G.file_has("  - [x] Syntax {#syntax}") and _G.line() == "  - [x] Syntax {#syntax}"]],
      note = "the key cycles [ ] -> [x], on disk and in the buffer",
    },
    { keys = ":Tasks point<CR>" },
    {
      expect = [[_G.file_has("  - [~] Syntax – Grund: nur angeschaut {#syntax}")]],
      note = "[x] -> [~] asks for the reason and writes it",
    },
    { keys = ":Tasks point open<CR>" },
    { expect = [[_G.file_has("  - [ ] Syntax {#syntax}")]], note = "a state by name" },
    {
      expect = [[_G.virt():find("0 gelernt", 1, true) ~= nil]],
      note = "the view is drawn again after the reload",
    },

    { keys = ":Tasks promote lib.nvim/lua-lernen#cc<CR>" },
    {
      expect = [[vim.fs.normalize(vim.api.nvim_buf_get_name(0)):sub(-#"lib.nvim/ROADMAP/tasks/c-compiler.md") == "lib.nvim/ROADMAP/tasks/c-compiler.md"]],
      note = "promote opens the new task",
    },
    {
      expect = [[_G.file_has("C-Compiler \226\134\146 lib.nvim/c-compiler {#cc}") and not _G.file_has("K&R")]],
      note = "the point's line names the task, the subtree moved",
    },
    { keys = ":Tasks unpromote lib.nvim/lua-lernen#cc<CR>" },
    {
      expect = [[_G.file_has("  - [ ] C-Compiler {#cc}\n    - [ ] K&R lesen")]],
      note = "unpromote brings the subtree back",
    },

    {
      expect = [[vim.v.errmsg == "" and not vim.fn.execute("messages"):find("rror", 1, true)]],
      note = "no error in v:errmsg or :messages",
    },
  },
  judge = {},
  manual = {
    ":Tasks learn image on a point with an image shows it in the terminal through images.nvim (WezTerm), and in mdview.nvim's browser preview where images.nvim is missing",
    "the progress after a parent and the [image] line below a point read well in the real colour scheme; zc / zo fold a parent",
  },
}
