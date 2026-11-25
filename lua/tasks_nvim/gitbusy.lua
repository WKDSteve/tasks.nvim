---@module 'tasks_nvim.gitbusy'
-- lua/tasks_nvim/gitbusy.lua -- is git rewriting the working tree of a vault right now?

---A vault is usually a git checkout that several sessions share. While one of them pulls with a rebase and an
---autostash (or merges, cherry-picks, or runs any command holding `index.lock`), the files of the tree are not what
---they will be a moment later: the autostash sets every changed file back to HEAD and writes the changes back at the
---end.
---A `done` that reads a task in that window finishes the old text, and the open file comes back afterwards: one task
---in two places. The lock of `fsio.with_lock` only keeps tasks.nvim from itself; this module looks at git.
---
---It reads the state files git leaves in the git directory of the checkout (a `.git` folder, or the folder a `.git`
---file names in a worktree), from the vault root upwards. It starts no process.
local fsio = require("tasks_nvim.fsio")

local M = {}

---What git leaves in its directory while it rewrites the tree, and the words for it.
---@type { [1]: string, [2]: string }[]
M.MARKERS = {
  { "rebase-merge", "a rebase (or a pull with --rebase and --autostash)" },
  { "rebase-apply", "a rebase or git am" },
  { "MERGE_HEAD", "a merge" },
  { "CHERRY_PICK_HEAD", "a cherry-pick" },
  { "REVERT_HEAD", "a revert" },
  { "index.lock", "another git command (it holds index.lock)" },
}

---How long `wait` looks before it gives up, in milliseconds. A pull with an autostash takes well under a second.
M.WAIT_MS = 3000

---How often `wait` looks, in milliseconds.
M.POLL_MS = 50

---A seam for specs: wait up to `ms` until `cond()` is true. `vim.wait` keeps the editor's loop running.
---@param ms integer
---@param cond fun(): boolean
---@param interval integer
M.sleep_until = function(ms, cond, interval)
  vim.wait(ms, cond, interval)
end

---The git directory of the checkout `root` lies in, or `nil` when it is in none.
---@param root string
---@return string|nil
function M.git_dir(root)
  local dir = fsio.norm(root)
  for _ = 1, 64 do
    local dot = dir .. "/.git"
    if fsio.is_dir(dot) then
      return dot
    end
    if fsio.is_file(dot) then
      local text = fsio.read(dot)
      local target = type(text) == "string" and text:match("^gitdir:%s*(.-)%s*$") or nil
      if not target or target == "" then
        return nil
      end
      target = fsio.norm(target)
      if not (target:match("^%a:/") or target:sub(1, 1) == "/") then
        target = dir .. "/" .. target
      end
      return target
    end
    local parent = fsio.dirname(dir)
    if parent == dir or parent == "." or parent == "" then
      return nil
    end
    dir = parent
  end
  return nil
end

---What git is doing in the checkout of `root` right now, or `nil` when it rewrites nothing.
---@param root string
---@return string|nil what   # The words for it (`a rebase ...`).
---@return string|nil path   # The state file or folder that says so.
function M.busy(root)
  local gd = M.git_dir(root)
  if not gd then
    return nil
  end
  for _, m in ipairs(M.MARKERS) do
    local path = gd .. "/" .. m[1]
    if fsio.stat(path) then
      return m[2], path
    end
  end
  return nil
end

---Wait until git rewrites nothing in the checkout of `root` (at most `opts.git_wait_ms`, default `WAIT_MS`).
---@param root string
---@param opts? { git_wait_ms?: integer }
---@return string|nil what   # `nil`: git is idle. Otherwise what is still running after the wait.
---@return string|nil path
function M.wait(root, opts)
  local what, path = M.busy(root)
  if not what then
    return nil
  end
  local ms = (opts and opts.git_wait_ms) or M.WAIT_MS
  if ms > 0 then
    M.sleep_until(ms, function()
      what, path = M.busy(root)
      return what == nil
    end, M.POLL_MS)
  end
  return what, path
end

---The error a write gives when git is still busy after the wait. The words `git is rewriting the vault` are what the
---contract maps to `locked`, retryable (`contract.ERROR_PATTERNS`): try again in a moment.
---@param what string
---@param path string
---@return string
function M.message(what, path)
  local msg = ("git is rewriting the vault (%s: %s); nothing was changed, run it again once git is done"):format(
    what,
    path
  )
  if path:match("index%.lock$") then
    msg = msg .. " (no git command running? then the lock is left over: remove it)"
  end
  return msg
end

return M
