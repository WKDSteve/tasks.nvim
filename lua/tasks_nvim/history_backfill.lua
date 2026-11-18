---@module 'tasks_nvim.history_backfill'
---@brief Fill the series of `tasks_nvim.history` for past days from the history of the vault's repository.
---@description
--- The series starts on the day the first row is written. What the vault looked like before is still in git: for
--- every past day that has a commit and no row, the tree of the last commit of that day is laid out in a temporary
--- folder, counted with the engine of today, and written as rows marked `src: "git"` (`at` is the time of the commit).
---
---  - only days WITHOUT a row are filled: a row that was written on its day is what the vault was, a count from git
---    is the next best thing and never replaces it;
---  - a day without a commit gets no row (nothing changed), today is left to `history.record`;
---  - a tree the engine of today cannot read is skipped and named (a gap stays a gap, nothing is guessed);
---  - the repository is not touched: the trees are laid out through an index file of their own
---    (`GIT_INDEX_FILE`), in a folder that is removed afterwards. No worktree, no branch, no stash.
---
--- The day of a commit is the day of its committer time on this machine (the same clock `model.today` reads).
---
--- Not its job: the rows themselves and the reading (`history`), the command line (`cli`). Needs `git`; the web
--- variant never calls it.
-- @scans-data

local contract = require("tasks_nvim.contract")
local fsio = require("tasks_nvim.fsio")
local history = require("tasks_nvim.history")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---`git` in `dir`, or nil and what it said.
---@param dir string
---@param args string[]
---@param env? table<string, string>
---@return string|nil stdout
---@return string|nil err
local function git(dir, args, env)
  local cmd = vim.list_extend({ "git", "-C", dir }, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, env = env }):wait()
  end)
  if not ok then
    return nil, "git cannot be started"
  end
  if res.code ~= 0 then
    return nil, ("git %s: %s"):format(args[1], vim.trim(res.stderr or ""))
  end
  return res.stdout or ""
end

---@class Tasks.BackfillDay
---@field day string   # `YYYY-MM-DD`, on this machine's clock
---@field sha string   # the last commit of that day
---@field at string    # its committer time, UTC

---The days of the history of `HEAD` that have a commit, oldest first, each with its last commit.
---@param top string  # the top of the repository
---@return Tasks.BackfillDay[]|nil days
---@return string|nil err
function M.days(top)
  local out, err = git(top, { "log", "--first-parent", "--format=%H %ct", "HEAD" })
  if not out then
    return nil, err
  end
  local seen, days = {}, {}
  -- newest first: the first commit seen of a day is its last one
  for sha, stamp in out:gmatch("(%x+) (%d+)") do
    local time = tonumber(stamp)
    local day = time and os.date("%Y-%m-%d", time) --[[@as string|nil]]
    if day and model.is_date(day) and not seen[day] then
      seen[day] = true
      days[#days + 1] = {
        day = day,
        sha = sha,
        at = os.date("!%Y-%m-%dT%H:%M:%SZ", time) --[[@as string]],
      }
    end
  end
  table.sort(days, function(a, b)
    return a.day < b.day
  end)
  return days
end

---@class Tasks.BackfillResult
---@field days integer        # Days that were counted.
---@field rows integer        # Rows written (a dry run: that would be written).
---@field first? string       # The first day counted.
---@field last? string        # The last day counted.
---@field skipped { day: string, why: string }[]  # Days whose tree could not be counted.
---@field kept integer        # Days left alone because they have a row already.

---Fill the days before today that have a commit and no row.
---@param opts? { root?: string, today?: string, since?: string, until?: string, dry_run?: boolean, progress?: fun(day: string, n: integer, of: integer) }
---@return Tasks.BackfillResult|nil result
---@return string|nil err
function M.run(opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, tostring(rerr)
  end
  local today = opts.today or model.today()
  for _, name in ipairs({ "today", "since", "until" }) do
    local v = name == "today" and today or opts[name]
    if v ~= nil and not model.is_date(v) then
      return nil, name .. " must be a day, YYYY-MM-DD"
    end
  end
  local top, terr = git(root, { "rev-parse", "--show-toplevel" })
  if not top then
    return nil, terr
  end
  top = fsio.norm(vim.trim(top))
  local prefix = vim.trim(git(root, { "rev-parse", "--show-prefix" }) or "")
  local git_dir, gerr = git(root, { "rev-parse", "--absolute-git-dir" })
  if not git_dir then
    return nil, gerr
  end
  local all, derr = M.days(top)
  if not all then
    return nil, derr
  end
  local read = history.read(root)
  local days, kept = {}, 0
  for _, d in ipairs(all) do
    local inside = d.day < today
      and (opts.since == nil or d.day >= opts.since)
      and (opts["until"] == nil or d.day <= opts["until"])
    if inside and read.days[d.day] then
      kept = kept + 1
    elseif inside then
      days[#days + 1] = d
    end
  end

  ---@type Tasks.BackfillResult
  local result = { days = 0, rows = 0, skipped = {}, kept = kept }
  if #days == 0 then
    return result
  end

  local tmp = fsio.norm(vim.fn.tempname())
  local tree = tmp .. "/tree"
  -- the environment of the child: everything of this process plus the three that keep git off the real index and
  -- tree. git runs INSIDE the temporary tree (a command that writes files refuses to run outside its work tree).
  local env = {
    GIT_DIR = vim.trim(git_dir),
    GIT_INDEX_FILE = tmp .. "/index",
    GIT_WORK_TREE = tree,
  }
  local tree_root = (tree .. "/" .. prefix):gsub("/+$", "")
  local new_rows = {}

  local function run()
    vim.fn.mkdir(tree, "p")
    local state, next_row = {}, 1
    local prev = nil
    for n, d in ipairs(days) do
      if opts.progress then
        opts.progress(d.day, n, #days)
      end
      -- the rows that exist for earlier days are the state this day is compared with
      while read.rows[next_row] and read.rows[next_row].day < d.day do
        state[read.rows[next_row].area] = read.rows[next_row]
        next_row = next_row + 1
      end
      local _, cerr
      if prev then
        -- from one tree to the next: only the files that differ are written
        _, cerr = git(tree, { "read-tree", "-m", "-u", prev, d.sha }, env)
      else
        -- `-u` also stores what the files look like on disk: without it the next step finds every file "not uptodate"
        _, cerr = git(tree, { "read-tree", "--reset", "-u", d.sha }, env)
      end
      if cerr then
        return nil, cerr
      end
      prev = d.sha
      local ok, view, verr = pcall(function()
        return fsio.read_scope(function()
          return contract.build_view({ root = tree_root })
        end)
      end)
      if not ok or not view then
        local why = tostring(not ok and view or verr):gsub(vim.pesc(tmp), "<tree>")
        result.skipped[#result.skipped + 1] = { day = d.day, why = why }
      else
        local rows = history.changes(state, history.figures(view), d.day, d.at, "git")
        for _, row in ipairs(rows) do
          state[row.area] = row
          new_rows[#new_rows + 1] = row
        end
        result.days = result.days + 1
        result.first = result.first or d.day
        result.last = d.day
      end
    end
    return true
  end

  local ran, ok, err = pcall(run)
  vim.fn.delete(tmp, "rf")
  -- the parse cache holds the files of the folder that is gone
  model.reset_parse_cache()
  if not ran then
    return nil, tostring(ok)
  end
  if not ok then
    return nil, err
  end
  result.rows = #new_rows
  if #new_rows > 0 and not opts.dry_run then
    local wrote, werr = history.write_rows(root, new_rows)
    if not wrote then
      return nil, werr
    end
  end
  return result
end

return M
