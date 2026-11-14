-- TESTS/tasks_tree_drive_spec.lua -- the vault in the real own tree of filetree.nvim: the badge next to an area
-- folder, the view `tasks`, and the actions claim and done pressed on a node. `tasks_tree_spec.lua` checks the
-- registered entries; this one checks that a tree which reads them shows and runs them.
--
-- A script in its own Neovim (`dialect = "script"` in .testing.lua): it sits on filetree.nvim's bench
-- `TESTS/native_drive.lua`, which sets up the editor and quits it. filetree.nvim is no dependency of tasks.nvim:
-- the run needs `$FILETREE_NVIM_DIR` and says so and passes without it (so the suite and the CI leave it out).
-- Run:  FILETREE_NVIM_DIR=<checkout> nvim --clean --headless -u NONE -l TESTS/tasks_tree_drive_spec.lua
-- @scans-data: it lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, duplicate-set-field

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h"):gsub("\\", "/")
local plugin = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin)

---The first folder of `candidates` that holds `rel`.
local function find(candidates, rel)
  -- not ipairs: a candidate that is not set (an environment variable) is a hole in the list
  for i = 1, #candidates do
    local dir = candidates[i]
    if dir and dir ~= "" and vim.uv.fs_stat(dir .. "/" .. rel) then
      return (dir:gsub("\\", "/"))
    end
  end
  return nil
end

-- Nothing of the person's own setup reaches this run: no real vault, no documents a finish would refresh
-- (`$TASKS_MARKER_DOCS`), and the state files (frecency, checkpoints) go to a temp folder.
local scratch = vim.fn.tempname():gsub("\\", "/")
vim.fn.mkdir(scratch, "p")
for _, var in ipairs({
  "TASKS_VAULT",
  "TASKS_MARKER_DOCS",
  "TASKS_EXTRA_AREAS",
  "TASKS_LINKS",
  "TASKS_FRECENCY_FILE",
  "TASKS_LISTS_FILE",
}) do
  vim.env[var] = nil
end
for _, var in ipairs({ "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME" }) do
  vim.env[var] = scratch
end

local repos = vim.env.REPOS_DIR
-- Only where it is named: a sibling checkout is somebody's working tree, and its state of the hour must not
-- decide whether the suite of tasks.nvim is green.
local filetree = find({ vim.env.FILETREE_NVIM_DIR or "" }, "TESTS/native_drive.lua")
if not filetree then
  io.stdout:write("  n/a  filetree.nvim not found: the run through the own tree is left out\n")
  io.stdout:write("\ntasks.nvim tasks_tree_drive_spec: 0 passed, 0 failed\n")
  vim.cmd("qa!")
  return
end
-- the bench looks for lib.nvim and ui.nvim next to filetree.nvim, or where these name them
for _, dep in ipairs({ "lib.nvim", "ui.nvim" }) do
  local var = dep:upper():gsub("%.", "_") .. "_DIR"
  if not vim.env[var] or vim.env[var] == "" then
    local dir = find({
      vim.fs.dirname(plugin) .. "/" .. dep,
      plugin .. "/.deps/" .. dep,
      repos and (repos .. "/" .. dep) or "",
    }, "lua")
    if dir then
      vim.env[var] = dir
    end
  end
end

local function task(title, status)
  return { "---", "title: " .. title, "status: " .. status, "---", "", title .. " in one line." }
end

local index, tasks_nvim
local T = dofile(filetree .. "/TESTS/native_drive.lua")({
  name = "tasks_tree_drive_spec (tasks.nvim)",
  files = {
    "README.md",
    "lib.nvim/ROADMAP/tasks/alpha.md",
    "lib.nvim/ROADMAP/tasks/beta.md",
    "cascade.nvim/ROADMAP/tasks/gamma.md",
    "cascade.nvim/Backlog/README.md",
    "lib.nvim/Backlog/README.md",
  },
  before_setup = function(T)
    T.mkfile("lib.nvim/ROADMAP/tasks/alpha.md", task("Alpha", "open"))
    T.mkfile("lib.nvim/ROADMAP/tasks/beta.md", task("Beta", "open"))
    T.mkfile("cascade.nvim/ROADMAP/tasks/gamma.md", task("Gamma", "open"))
    vim.fn.mkdir(T.dir .. "/lib.nvim/Backlog/TASKS", "p")
    vim.fn.mkdir(T.dir .. "/lib.nvim/Backlog/FEATURES", "p")
    tasks_nvim = require("tasks_nvim")
    tasks_nvim.setup({
      vault = T.dir,
      reminders = { on_start = false },
      next = { popup = false },
      tree = { keys = { claim = "gC", done = "gD" } },
    })
    index = require("tasks_nvim.index")
    local _, errors = index.write_all({ root = T.dir })
    assert(#errors == 0, vim.inspect(errors))
  end,
})

local function has(name, text, needle)
  T.ok(
    name .. "  -- " .. vim.inspect(text),
    type(text) == "string" and text:find(needle, 1, true) ~= nil
  )
end

---The line of the tree buffer that contains `needle`, 1-based.
local function line_of(needle)
  for i, line in ipairs(T.lines()) do
    if line:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

---Put the tree's cursor on the line that shows `needle`.
local function on_line(needle)
  T.tree()
  T.wait(function()
    return line_of(needle) ~= nil
  end)
  local line = assert(line_of(needle), "the tree does not show " .. needle)
  vim.api.nvim_win_set_cursor(T.adapter.get_winid(), { line, 0 })
  vim.cmd("doautocmd CursorMoved")
end

local function status_of(rel)
  for _, line in ipairs(T.read(rel)) do
    local status = line:match("^status:%s*(%S+)")
    if status then
      return status
    end
  end
  return nil
end

-- ── the badge in the file view ───────────────────────────────────────────────
T.on("lib.nvim")
T.wait(function()
  local drawn = T.drawn("lib.nvim")
  return drawn and drawn.text:find("2", 1, true) ~= nil
end)
has("an area folder shows its open tasks", T.drawn("lib.nvim").text, "2")
has("... each area its own", T.drawn("cascade.nvim").text, "1")
T.on("lib.nvim/ROADMAP/tasks/alpha.md")
has("... and so does ROADMAP/tasks below it", T.drawn("lib.nvim/ROADMAP/tasks").text, "2")
T.eq("a task file has no badge", T.drawn("lib.nvim/ROADMAP/tasks/alpha.md").text, "")

-- a task is created and the index written: the badge follows without a refresh
T.mkfile("lib.nvim/ROADMAP/tasks/delta.md", task("Delta", "open"))
assert(index.write_area("lib.nvim", { root = T.dir }))
T.ok(
  "a written index moves the badge",
  T.wait(function()
    return T.drawn("lib.nvim").text:find("3", 1, true) ~= nil
  end)
)

-- ── claim on the task file, in the file view ─────────────────────────────────
vim.env.TASKS_CLAIM_BY = nil
local mark = T.mark()
T.on("lib.nvim/ROADMAP/tasks/alpha.md")
T.feed("gC")
T.ok(
  "gC on a task file claims the task",
  T.wait(function()
    return status_of("lib.nvim/ROADMAP/tasks/alpha.md") == "doing"
  end)
)
T.ok("... and says so", T.told("claimed lib.nvim/alpha", mark))
T.eq("... without a warning", T.loud(mark), {})

-- on a file that is no task the key says why it does nothing
mark = T.mark()
T.on("README.md")
T.feed("gC")
T.settle()
T.eq("gC on another file claims nothing", status_of("lib.nvim/ROADMAP/tasks/beta.md"), "open")
T.ok("... and no task is named", not T.told("claimed", mark))

-- ── the view ─────────────────────────────────────────────────────────────────
T.tree()
vim.cmd("Filetree source tasks")
T.ok(
  "the view lists the areas with open tasks",
  T.wait(function()
    return line_of("lib.nvim") ~= nil and line_of("cascade.nvim") ~= nil
  end)
)
has("... with the badge of the area folder", T.drawn("lib.nvim").text, "3")
on_line("lib.nvim")
T.feed("<CR>")
T.ok(
  "an area opens to its tasks",
  T.wait(function()
    return line_of("Alpha") ~= nil and line_of("Beta") ~= nil and line_of("Delta") ~= nil
  end)
)
has("... each with its state", T.drawn("lib.nvim/ROADMAP/tasks/alpha.md").text, "doing")
has("... each with its state", T.drawn("lib.nvim/ROADMAP/tasks/beta.md").text, "open")
T.ok("... the claimed one first, as in the index", line_of("Alpha") < line_of("Beta"))

-- done on a task node: it asks, and the task leaves the view
local confirm = require("tasks_nvim.ui.confirm")
local asked = {}
confirm.yesno = function(question, _, cb)
  asked[#asked + 1] = question
  cb(true)
end
mark = T.mark()
on_line("Beta")
T.feed("gD")
T.ok(
  "gD on a task node finishes the task",
  T.wait(function()
    return not T.exists("lib.nvim/ROADMAP/tasks/beta.md")
  end)
)
T.eq("... after one question", #asked, 1)
has("... that names the task", asked[1], "Finish task lib.nvim/beta?")
T.ok(
  "... and the view drops it",
  T.wait(function()
    return line_of("Beta") == nil
  end)
)
T.ok("... while the others stay", line_of("Alpha") ~= nil and line_of("Delta") ~= nil)
T.ok(
  "... and the count of the area follows",
  T.wait(function()
    return T.drawn("lib.nvim").text:find("2", 1, true) ~= nil
  end)
)
T.eq("... without a warning", T.loud(mark), {})

-- <CR> on a task node opens its file
on_line("Delta")
T.feed("<CR>")
T.ok(
  "<CR> on a task opens its file",
  T.wait(function()
    return vim.api.nvim_buf_get_name(0):gsub("\\", "/"):find("ROADMAP/tasks/delta.md", 1, true)
      ~= nil
  end)
)

T.eq("no dialog nobody expected", T.unanswered, 0)
tasks_nvim.setup({ tree = false, reminders = { on_start = false } })
vim.fn.delete(scratch, "rf")
T.finish()
