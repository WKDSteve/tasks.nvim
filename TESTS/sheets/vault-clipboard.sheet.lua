-- `:TasksVault clipboard <area>` puts the path of the area's Backlog on the system clipboard through
-- `lib.nvim.cross.copy_to_clipboard`: the `+` register first, then the program of the platform with the text on stdin
-- (`powershell -Command "$input | Set-Clipboard"` on Windows, `pbcopy` on macOS, `wl-copy`/`xclip`/`xsel` on Linux,
-- `clip.exe` in WSL). The sheet's `+` register keeps nothing (a provider that drops the text), so the program runs;
-- the programs are recording stand-ins (`fakes`): the sheet proves which one got called, not that the real clipboard
-- holds the text (`manual`).
-- A fixture vault in a temp folder (never a real vault).
local CLIPS = { "powershell", "pbcopy", "wl-copy", "xclip", "xsel", "clip.exe" }

return {
  id = "tasks.vault-clipboard",
  feature = "tasks.vault-clipboard",
  title = "tasks.nvim: :TasksVault clipboard copies the Backlog path with the clipboard program of the platform",
  engine = "rpc",
  sizes = { { rows = 24, cols = 120 } },
  fakes = CLIPS,
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
      _G.said = function(text) return vim.fn.execute("messages"):find(text, 1, true) ~= nil end
      _G.calls = function()
        local fp, out = require("testing.fake_programs"), {}
        for _, p in ipairs({ "powershell", "pbcopy", "wl-copy", "xclip", "xsel", "clip.exe" }) do
          for _, c in ipairs(fp.read(vim.env.TESTING_FAKES, p)) do
            out[#out + 1] = c
          end
        end
        return out
      end]],
      note = "a fixture vault",
    },
    {
      lua = [[local drop = function() end
      local nothing = function() return { {}, "v" } end
      vim.g.clipboard = {
        name = "sheet-drops-text",
        copy = { ["+"] = drop, ["*"] = drop },
        paste = { ["+"] = nothing, ["*"] = nothing },
      }]],
      note = "a + register that keeps nothing, as on a machine without a clipboard provider",
    },
    {
      lua = [[if vim.fn.has("win32") == 1 then
        local path = vim.fn.getcwd() .. "/TESTS/sheets/fixtures/windows_stand_in_argv.lua"
        assert(load(table.concat(vim.fn.readfile(path), "\n"), "=windows stand-in argv"))({ "powershell" })
      end]],
      note = "Windows: the stand-in gets the script without the | of PowerShell (a .cmd stand-in would run it)",
    },
    { keys = ":TasksVault clipboard lib.nvim<CR>" },
    {
      wait = [[#_G.calls() == 1]],
      timeout = 5000,
      note = "one clipboard program was started",
    },
    {
      expect = [[_G.said("Copied ") and _G.said("lib.nvim")]],
      note = "the copy is reported with the path",
    },
    {
      expect = [[vim.v.errmsg == "" and not vim.fn.execute("messages"):find("rror", 1, true)]],
      note = "no error in v:errmsg or :messages",
    },
  },
  judge = {},
  manual = {
    "Once in the real editor: :TasksVault clipboard lib.nvim, then paste elsewhere: the path of the Backlog",
  },
}
