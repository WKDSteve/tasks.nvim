-- `tasks ci --md-lint=<script>` (the CLI gate): the rule check, the freshness of every index, then the generated indexes
-- through a Markdown linter in a child Neovim (`nvim --headless -u NONE -l <script> <files>`), waited for while it runs.
-- A user (or a hook) types it in a shell (`nvim -l scripts/tasks.lua`); the trace of `testing perf` does not follow into
-- that child, so the sheet calls the same entry, `tasks_nvim.cli.run(argv, io)`, with the user's words, in the editor
-- it drives. The child Neovim of the linter is real; the linter is a small script of the fixture.
-- A fixture vault in a temp folder (never a real vault).
return {
  id = "tasks.cli-ci",
  feature = "tasks.cli-ci",
  title = "tasks.nvim: tasks ci runs the gate and lints the generated indexes in a child Neovim",
  engine = "rpc",
  sizes = { { rows = 24, cols = 100 } },
  steps = {
    {
      lua = [[local H = {
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
      F.task(H, _G.root, "lib.nvim", "alpha", F.meta("Alpha", "open"))
      F.task(H, _G.root, "cascade.nvim", "beta", F.meta("Beta", "open"))
      -- the linter: every file must have a heading; it says OK per file
      _G.md_lint = vim.fs.dirname(_G.root) .. "/md_lint.lua"
      H.write(_G.md_lint, table.concat({
        "local bad = 0",
        "for _, file in ipairs(arg) do",
        "  local heading = false",
        "  for line in io.lines(file) do heading = heading or line:sub(1, 2) == '# ' end",
        "  if heading then print('OK ' .. file) else print(file .. ': no heading'); bad = bad + 1 end",
        "end",
        "os.exit(bad == 0 and 0 or 1)",
      }, "\n"))
      _G.cli = function(argv)
        local out = {}
        local io = { out = function(s) out[#out + 1] = s end, err = function(s) out[#out + 1] = s end }
        return require("tasks_nvim.cli").run(argv, io), table.concat(out)
      end
      assert(_G.cli({ "--vault=" .. _G.root, "index" }) == 0, "index")]],
      note = "a fixture vault with its indexes written, and a Markdown linter",
    },
    {
      lua = [[_G.code, _G.out = _G.cli({ "--vault=" .. _G.root, "ci", "--md-lint=" .. _G.md_lint })]],
      timeout = 30000,
      note = "tasks --vault=<vault> ci --md-lint=<script>",
    },
    {
      expect = [[_G.out:find("md_lint: 2 index file(s) clean -- ok", 1, true) ~= nil]],
      note = "the linter ran over both generated indexes and found them clean",
    },
  },
  judge = {},
  manual = {},
}
