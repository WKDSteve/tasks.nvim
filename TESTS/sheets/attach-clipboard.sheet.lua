-- `:Tasks attach <id> from=clipboard` reads the image on the system clipboard through `lib.nvim.clipboard_image`: one
-- program of the platform (`powershell.exe -STA` on Windows, `pngpaste` on macOS, `wl-paste`/`xclip` on Linux), which
-- blocks the editor until it answers. The programs are recording stand-ins (`fakes`) that hand back no image, so the
-- sheet sees the case of an empty clipboard: the program was asked, the user is told, nothing is attached. The image
-- itself (a PNG lands in assets/screenshots/ and the link at the cursor) is `manual`; the specs check it with a replaced
-- runner (tasks_attach_source_spec).
-- A fixture vault in a temp folder (never a real vault).
return {
  id = "tasks.attach-clipboard",
  feature = "tasks.attach-clipboard",
  title = "tasks.nvim: :Tasks attach <id> from=clipboard asks the clipboard program of the platform for the image",
  engine = "rpc",
  sizes = { { rows = 24, cols = 120 } },
  fakes = { "powershell", "pngpaste", "wl-paste", "xclip" },
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
      F.task(H, _G.root, "lib.nvim", "show-the-bug", F.meta("Show the bug", "open"))
      require("tasks_nvim").setup({ vault = _G.root })
      _G.said = function(text) return vim.fn.execute("messages"):find(text, 1, true) ~= nil end
      _G.calls = function()
        local fp, out = require("testing.fake_programs"), {}
        for _, p in ipairs({ "powershell", "pngpaste", "wl-paste", "xclip" }) do
          for _, c in ipairs(fp.read(vim.env.TESTING_FAKES, p)) do
            out[#out + 1] = c
          end
        end
        return out
      end]],
      note = "a fixture vault with the task lib.nvim/show-the-bug",
    },
    {
      lua = [[if vim.fn.has("win32") == 1 then
        local path = vim.fn.getcwd() .. "/TESTS/sheets/fixtures/windows_stand_in_argv.lua"
        assert(load(table.concat(vim.fn.readfile(path), "\n"), "=windows stand-in argv"))({ "powershell" })
      end]],
      note = "Windows: powershell.exe reaches the stand-in by its bare name",
    },
    {
      keys = ":Tasks attach lib.nvim/show-the-bug from=clipboard<CR>",
      ignore_errmsg = true,
      note = "the error message of an empty clipboard is expected",
    },
    {
      expect = [[#_G.calls() == 1]],
      note = "one clipboard program was asked, while the command ran",
    },
    {
      expect = [[_G.said("no image in the clipboard")]],
      note = "the user is told the clipboard holds no image",
    },
    {
      expect = [[vim.fn.isdirectory(_G.root .. "/lib.nvim/ROADMAP/tasks/show-the-bug") == 0
        and vim.fn.isdirectory(_G.root .. "/lib.nvim/ROADMAP/tasks/assets") == 0]],
      note = "nothing is attached: the task stays a single file",
    },
  },
  judge = {},
  manual = {
    "Once in the real editor: copy a screenshot, then :Tasks attach <id> from=clipboard puts a PNG into assets/screenshots/ of the task and its link at the cursor",
  },
}
