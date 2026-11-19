-- Live check of `:Tasks meeting new|open|list|close` (task tasks.nvim/meetings-ops): typed in a real editor, so the
-- command line, the routes, the quick capture and the write door are checked together. The specs check the handlers
-- alone (tasks_meeting_cmd_spec). A fixture vault in a temp folder (never a real vault). The picker (`vim.ui.select`)
-- is recorded and answers with its first item; how the real picker looks is left to a person (`manual`).
return {
  id = "tasks.meeting-commands",
  title = "tasks.nvim: :Tasks meeting new, open (at a section), list (the coming first) and close",
  feature = "tasks.meetings",
  task = "tasks.nvim/meetings-ops",
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
      -- an older meeting that is done: the list puts the coming one first
      H.write(_G.root .. "/lib.nvim/MEETINGS/old-2026-01-10.md",
        "---\ntitle: Old\nstatus: done\ndate: 2026-01-10\n---\n\n## Ergebnis\n\nDone.\n")
      require("tasks_nvim").setup({ vault = _G.root })
      _G.picked = {}
      vim.ui.select = function(items, opts, on_choice)
        table.insert(_G.picked, { items = items, label = opts.format_item(items[1]) })
        on_choice(items[1])
      end
      _G.buf_ends = function(tail)
        return vim.fs.normalize(vim.api.nvim_buf_get_name(0)):sub(-#tail) == tail
      end
      _G.line = function()
        return vim.api.nvim_get_current_line()
      end
      _G.file_has = function(text)
        local f = io.open(_G.root .. "/lib.nvim/MEETINGS/sync-2026-12-07.md", "rb")
        local s = f and f:read("*a") or ""
        if f then f:close() end
        return s:find(text, 1, true) ~= nil
      end]],
      note = "a fixture vault with a finished meeting; the picker recorded",
    },

    { keys = ":Tasks meeting new lib.nvim 2026-12-07 14:00-15:00 Sync @Raum_1<CR>" },
    {
      expect = [[_G.buf_ends("lib.nvim/MEETINGS/sync-2026-12-07.md") and _G.line() == "## Agenda"]],
      note = "the meeting is made from the quick line and opened at its agenda",
    },
    {
      expect = [[_G.file_has('time: "14:00"') or _G.file_has("time: 14:00")]],
      note = "the time of the line is in the file",
    },
    { expect = [[_G.file_has("location: Raum 1")]], note = "@Raum_1 is the place, with a blank" },

    -- an empty buffer first: editing the open Markdown file again runs the undo of the runtime's markdown ftplugin,
    -- whose `silent! nunmap` sets v:errmsg (E31) without a message
    { keys = ":enew<CR>" },
    { keys = ":Tasks meeting open lib.nvim/sync-2026-12-07 --section=protokoll<CR>" },
    { expect = [[_G.line() == "## Protokoll"]], note = "open jumps to the minutes" },

    { keys = ":enew<CR>" },
    { keys = ":Tasks meeting list<CR>" },
    {
      expect = [[#_G.picked == 1 and _G.picked[1].items[1].id == "lib.nvim/sync-2026-12-07" and _G.picked[1].items[2].id == "lib.nvim/old-2026-01-10"]],
      note = "the picker offers the coming meeting first, the finished one after it",
    },
    {
      expect = [[_G.picked[1].label:find("2026-12-07 14:00", 1, true) ~= nil and _G.picked[1].label:find("@Raum 1", 1, true) ~= nil]],
      note = "a line names day, time and place",
    },
    {
      expect = [[_G.buf_ends("lib.nvim/MEETINGS/sync-2026-12-07.md")]],
      note = "the meeting picked is opened",
    },

    { keys = ":enew<CR>" },
    { keys = ":Tasks meeting close lib.nvim/sync-2026-12-07 --result=Vereinbart<CR>" },
    {
      expect = [[_G.file_has("status: done") and _G.file_has("Vereinbart")]],
      note = "close marks it done and writes the result",
    },

    {
      expect = [[vim.v.errmsg == "" and not vim.fn.execute("messages"):find("rror", 1, true)]],
      note = "no error in v:errmsg or :messages",
    },
  },
  judge = {},
  manual = {
    ":Tasks meeting list shows the real picker (snacks or the built-in select) with one line per meeting: day, time, status, title, place and id",
    "<Tab> after :Tasks meeting offers list, open, new and close, and after open/close the meeting ids are typed by hand",
  },
}
