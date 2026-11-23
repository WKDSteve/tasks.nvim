-- `:2,3Tasks new <area> <title>` (the command a visual selection ends in) writes the `code-ref/1` block of the marked
-- code under `## Kontext` of the new task (`tasks_nvim.code_ref`: repository name, commit, file relative to the git root,
-- lines, language and an excerpt). In a public area the excerpt goes in without a question; in a private area
-- (`new.private_areas`) the editor asks first, and a `n` writes the reference only: no excerpt. The block is checked by
-- the reader's check (`code_ref.task_problems`) before the sheet trusts it. The real mouse-and-eye walk through a
-- visual selection is `manual`.
-- A fixture vault and a fixture git repository in a temp folder (never a real vault or checkout); the repository is
-- made by the sheet, in steps of its own (its preparation, not the plugin's starts).
return {
  id = "tasks.code-ref",
  feature = "tasks.code-ref",
  title = "tasks.nvim: :2,3Tasks new writes the code-ref block; a private area asks before the excerpt",
  engine = "rpc",
  sizes = { { rows = 30, cols = 140 } },
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
      _G.repo = vim.fs.dirname(_G.root) .. "/my.repo"
      -- cascade.nvim is private, lib.nvim is not; nothing opens an app after the task is made
      require("tasks_nvim").setup({
        vault = _G.root,
        new = { open_after = "never", private_areas = { "cascade.nvim" }, private_vaults = { "nothing" } },
      })
      _G.task_text = function(slug)
        local found = vim.fn.glob(_G.root .. "/" .. slug, false, true)
        if #found ~= 1 then return nil end
        local f = assert(io.open(found[1], "rb"))
        local text = f:read("*a")
        f:close()
        return text
      end
      _G.block = function(slug)
        local text = _G.task_text(slug)
        if not text then return nil end
        local blocks = require("tasks_nvim.code_ref").blocks(text)
        if #blocks ~= 1 then return nil end
        return vim.json.decode(blocks[1])
      end
      _G.said = function(text) return vim.fn.execute("messages"):find(text, 1, true) ~= nil end]],
      note = "a fixture vault: lib.nvim public, cascade.nvim private",
    },
    {
      lua = [[local function git(...)
        local cmd = { "git", "-C", _G.repo, "-c", "user.name=Sheet", "-c", "user.email=sheet@example.test",
          "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", "-c", "core.autocrlf=false", ... }
        local res = vim.system(cmd, { text = true, env = { GIT_CONFIG_NOSYSTEM = "1" } }):wait(20000)
        assert(res.code == 0, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
      end
      vim.fn.mkdir(_G.repo .. "/lua", "p")
      vim.fn.writefile({ "local M = {}", "function M.work(x)", "  return x", "end", "return M" }, _G.repo .. "/lua/a.lua")
      git("init", "-q")
      git("add", "-A")
      git("commit", "-q", "-m", "init")]],
      note = "a git repository my.repo with one commit and lua/a.lua",
    },
    {
      lua = [[vim.cmd("edit " .. vim.fn.fnameescape(_G.repo .. "/lua/a.lua"))
      vim.bo.filetype = "lua"]],
      note = "the file is open (the range of the command names its lines 2 and 3)",
    },
    -- public area: no question
    {
      keys = ":2,3Tasks new lib.nvim Public area<CR>",
      note = "a task made from lines 2-3 in the public area",
    },
    {
      wait = [[_G.block("lib.nvim/ROADMAP/tasks/public-area*.md") ~= nil]],
      timeout = 10000,
      note = "the task carries exactly one code-ref block, written without a question",
    },
    {
      expect = [[(function()
        local b = _G.block("lib.nvim/ROADMAP/tasks/public-area*.md")
        return b.schema == "code-ref/1" and b.repo == "my.repo" and b.file == "lua/a.lua"
          and b.lines[1] == 2 and b.lines[2] == 3 and b.lang == "lua"
          and b.excerpt == "function M.work(x)\n  return x" and b.dirty == false
          and type(b.sha) == "string" and #b.sha >= 40
      end)()]],
      note = "repository name (not a path), repo-relative file, lines, language, clean tree, the two marked lines as excerpt",
    },
    {
      expect = [[(function()
        local text = _G.task_text("lib.nvim/ROADMAP/tasks/public-area*.md")
        local problems = require("tasks_nvim.code_ref").task_problems(text)
        local kontext, fence = text:find("## Kontext", 1, true), text:find("```code-ref", 1, true)
        return #problems == 1 and #problems[1].problems == 0 and kontext ~= nil and fence ~= nil and fence > kontext
      end)()]],
      note = "the block passes the check of the reader and stands under ## Kontext",
    },
    {
      expect = [[not _G.said("no code-ref block")]],
      note = "the block was not refused",
    },

    -- private area: the question first, n writes no excerpt
    {
      lua = [[vim.cmd("edit " .. vim.fn.fnameescape(_G.repo .. "/lua/a.lua"))
      vim.bo.filetype = "lua"]],
      note = "back in the source file: the new task was opened in the window",
    },
    {
      keys = ":2,3Tasks new cascade.nvim Private area<CR>",
      note = "the same selection in the private area",
    },
    {
      wait = [[vim.fn.glob(_G.root .. "/cascade.nvim/ROADMAP/tasks/private-area*.md", false, true)[1] ~= nil]],
      timeout = 10000,
      note = "the task file is made",
    },
    {
      wait = [[(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local cfg = vim.api.nvim_win_get_config(win)
          if cfg.relative ~= "" then
            local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
            if text:find("private", 1, true) and text:find("excerpt", 1, true) then return true end
          end
        end
        return false
      end)()]],
      timeout = 10000,
      note = "the dialog asks whether to write the excerpt of a private area",
    },
    {
      expect = [[_G.task_text("cascade.nvim/ROADMAP/tasks/private-area*.md"):find("code-ref", 1, true) == nil]],
      note = "while the question is open, no block is in the file",
    },
    { keys = "n", note = "the person says no" },
    {
      wait = [[_G.block("cascade.nvim/ROADMAP/tasks/private-area*.md") ~= nil]],
      timeout = 10000,
      note = "the reference is written after the answer",
    },
    {
      expect = [[(function()
        local b = _G.block("cascade.nvim/ROADMAP/tasks/private-area*.md")
        return b.excerpt == nil and b.truncated == nil and b.repo == "my.repo" and b.file == "lua/a.lua"
          and b.lines[1] == 2 and b.lines[2] == 3
      end)()]],
      note = "a no writes the reference (repository, file, lines) and no excerpt",
    },
    {
      expect = [[not _G.task_text("cascade.nvim/ROADMAP/tasks/private-area*.md"):find("return x", 1, true)]],
      note = "the code itself is nowhere in the private task",
    },
  },
  judge = {},
  manual = {
    "Once in the real editor: mark lines with V, press : and run Tasks new <area> <title> (the range of the marked lines is filled in by the editor); the block of the task shows the marked code",
  },
}
