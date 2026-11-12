-- Live check of the commands of the bindings checklist that had no automatic check yet (task
-- tasks.nvim/testblatt-bindings-checkliste): every verb of `:TasksVault` and `:Tasks planfile`, `:Tasks quickwins`,
-- typed in a real editor, so the command line, the routes and the handlers are checked together. The specs check the
-- handlers alone (tasks_vault_cmd_spec, tasks_plan_commands_spec).
-- A fixture vault in a temp folder (never a real vault). What leaves the editor goes through the seams and is recorded:
-- the clipboard (`vault_cmd.copy`), the file explorer (`ui.cmd.explorer_open`) and the picker of pickers.nvim
-- (`ui.cmd.pickers_backend`); that the real clipboard, explorer and picker do their part is left to a person (`manual`).
-- `:Tasks preview` opens a browser through mdview.nvim: only by hand.
return {
  id = "tasks.vault-and-plan-commands",
  title = "tasks.nvim: :TasksVault (every verb), :Tasks planfile and :Tasks quickwins from the command line",
  task = "tasks.nvim/testblatt-bindings-checkliste",
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
      _G.H = H
      local F = dofile(vim.fn.getcwd() .. "/TESTS/fixture.lua")
      _G.root = vim.fs.normalize(F.vault(H))
      F.task(H, _G.root, "lib.nvim", "tiny-and-worth-it", F.meta("Tiny and worth it", "open", {
        { "effort", "XS" }, { "value", "5" },
      }))
      F.task(H, _G.root, "lib.nvim", "large-and-vague", F.meta("Large and vague", "open", { { "effort", "L" } }))

      -- what leaves the editor, recorded
      _G.copied, _G.explored, _G.picked = {}, {}, {}
      require("tasks_nvim.ui.vault_cmd").copy = function(text)
        table.insert(_G.copied, text)
        return true
      end
      local ui = require("tasks_nvim.ui.cmd")
      ui.explorer_open = function(dir) table.insert(_G.explored, vim.fs.normalize(dir)) end
      ui.pickers_backend = function()
        return {
          dispatch = function(action, opts)
            table.insert(_G.picked, { action = action, root = vim.fs.normalize(opts.roots[1]), prompt = opts.prompt })
          end,
        }, "recorded"
      end
      require("tasks_nvim").setup({ vault = _G.root })

      _G.norm = function(p) return vim.fs.normalize(p or "") end
      -- the same folder: the temp folder of macOS is a link (/var -> /private/var), and one side may be resolved
      _G.same = function(a, b)
        local function real(p) return vim.fs.normalize(vim.uv.fs_realpath(p or "") or p or "") end
        return a ~= nil and b ~= nil and real(a) == real(b)
      end
      _G.ends = function(s, tail) s = _G.norm(s); return s:sub(-#tail) == tail end
      _G.last = function(list) return list[#list] end
      _G.buf_has = function(text)
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find(text, 1, true) ~= nil
      end
      _G.said = function(text) return vim.fn.execute("messages"):find(text, 1, true) ~= nil end
      _G.backlog = _G.root .. "/lib.nvim/Backlog"]],
      note = "a fixture vault with two tasks of lib.nvim; clipboard, explorer and picker recorded",
    },

    -- status
    { keys = ":TasksVault status<CR>" },
    { expect = [[_G.said("Vault: " .. _G.root)]], note = "status names the vault in use" },

    -- clipboard, paste, link
    { keys = ":TasksVault clipboard lib.nvim<CR>" },
    {
      expect = [[_G.same(_G.last(_G.copied), _G.backlog)]],
      note = "the path of the Backlog of lib.nvim is copied",
    },
    { keys = ":enew<CR>" },
    { keys = ":TasksVault paste lib.nvim<CR>" },
    {
      expect = [[_G.buf_has("lib.nvim") and _G.buf_has("Backlog")]],
      note = "the same path at the cursor",
    },
    {
      lua = [[vim.cmd.edit(vim.fn.fnameescape(_G.root .. "/notes.md"))]],
      note = "a file in the vault root",
    },
    { keys = ":TasksVault link lib.nvim<CR>" },
    {
      expect = [[_G.buf_has("](lib.nvim/Backlog")]],
      note = "a Markdown link relative to the current file",
    },

    -- open, tree
    { keys = ":TasksVault open lib.nvim<CR>" },
    {
      expect = [[_G.ends(vim.api.nvim_buf_get_name(0), "/lib.nvim/Backlog/README.md")]],
      note = "the index of the Backlog in a buffer",
    },
    { keys = ":TasksVault tree lib.nvim tasks<CR>" },
    {
      expect = [[_G.same(_G.last(_G.explored), _G.backlog .. "/TASKS")]],
      note = "the folder of the part (tasks: Backlog/TASKS) in the explorer",
    },

    -- find, grep
    { keys = ":TasksVault find lib.nvim<CR>" },
    {
      expect = [[_G.last(_G.picked).action == "files" and _G.same(_G.last(_G.picked).root, _G.backlog)]],
      note = "a picker of files rooted at the Backlog",
    },
    { keys = ":TasksVault grep lib.nvim all<CR>" },
    {
      expect = [[_G.last(_G.picked).action == "grep" and _G.same(_G.last(_G.picked).root, _G.root .. "/lib.nvim")]],
      note = "a content search over the whole area",
    },

    -- cdx
    { keys = ":TasksVault cdx lib.nvim<CR>" },
    {
      expect = [[_G.last(_G.copied):find("^Read ") ~= nil and _G.norm(_G.last(_G.copied)):find(_G.backlog, 1, true) ~= nil]],
      note = "a prompt for Claude Code naming the folder is copied",
    },

    -- new
    { keys = ":TasksVault new task Call the plumber --area=lib.nvim<CR>" },
    {
      expect = [[_G.norm(vim.api.nvim_buf_get_name(0)):match("/lib%.nvim/Backlog/TASKS/%d%d%d%d%-%d%d%-%d%d_[^/]+%.md$") ~= nil]],
      note = "a dated note in Backlog/TASKS, opened",
    },
    {
      expect = [[table.concat(vim.fn.readfile(_G.backlog .. "/README.md"), "\n"):find("Call the plumber", 1, true) ~= nil]],
      note = "its row in the Backlog README",
    },

    -- :Tasks planfile, :Tasks quickwins
    { keys = ":Tasks planfile lib.nvim Ship the phone app --phases=capture,review<CR>" },
    {
      expect = [[vim.fn.filereadable(_G.root .. "/lib.nvim/ROADMAP/plans/ship-the-phone-app.md") == 1]],
      note = "the plan file is made",
    },
    {
      expect = [[table.concat(vim.fn.readfile(_G.root .. "/lib.nvim/ROADMAP/plans/ship-the-phone-app.md"), "\n"):find("capture", 1, true) ~= nil]],
      note = "with its stages",
    },
    { keys = ":Tasks quickwins lib.nvim<CR>" },
    {
      wait = [[_G.buf_has("Tiny and worth it")]],
      note = "the quick win is listed",
    },
    { expect = [[not _G.buf_has("Large and vague")]], note = "a large task is no quick win" },

    -- create (last: it switches the vault of the session)
    { lua = [[_G.other = _G.H.tmpdir() .. "/second-vault"]] },
    {
      lua = [[vim.cmd("TasksVault create --force --yes " .. vim.fn.fnameescape(_G.other) .. " work")]],
      note = ":TasksVault create --force --yes <dir> work",
    },
    {
      expect = [[vim.fn.isdirectory(_G.other .. "/work") == 1 and _G.same(require("tasks_nvim.vault").root(), _G.other)]],
      note = "the vault and its area are made and used for this session",
    },
    {
      expect = [[_G.last(_G.copied):find(_G.norm(_G.other), 1, true) ~= nil or _G.norm(_G.last(_G.copied)):find(_G.norm(_G.other), 1, true) ~= nil]],
      note = "the setup line that keeps it is copied",
    },

    {
      expect = [[vim.v.errmsg == "" and not vim.fn.execute("messages"):find("rror", 1, true)]],
      note = "no error in v:errmsg or :messages",
    },
  },
  judge = {},
  manual = {
    ":TasksVault clipboard lib.nvim and :TasksVault cdx lib.nvim put their text into the real system clipboard (paste it elsewhere)",
    ":TasksVault tree lib.nvim opens the folder in filetree.nvim (or the built-in browser without it)",
    ":TasksVault find lib.nvim and :TasksVault grep lib.nvim open the real picker of pickers.nvim rooted at the folder",
    ":Tasks preview <id> shows the task rendered in the browser through mdview.nvim, and nothing is written to the vault",
  },
}
