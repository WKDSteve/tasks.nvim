---@module 'tasks_nvim.vault_merge'
---@brief A merge way for the generated files of a shared vault: a conflict in `ROADMAP/TASKS.md` is no conflict.
---@description
--- `ROADMAP/TASKS.md` is generated from the task files and rewritten by every call of the engine in the working
--- tree, while other sessions commit their own version of it. A text merge of two renderings conflicts for as long
--- as two sessions touch tasks of one area (`git pull --rebase --autostash`, `stash apply`, `cherry-pick`). The
--- file is not worth a hand merge: it is the same function of the task files every time.
---
--- The driver (`tasks merge-driver %O %A %B %P`, git's `merge.tasks-index.driver`) never leaves a conflict: it
--- merges the three versions by lines when that works, and keeps "our" version when it does not. The result may
--- then be an old rendering of the merged tasks; that is what the next `tasks index <area>` (every CLI call that
--- writes, `tasks commit`, `tasks push`) renders anew, and what the pre-push gate (`index-stale`) checks. Git
--- merges the files of a merge before it writes the working tree, so the driver cannot read the merged task files
--- itself.
---
--- `Backlog/README.md` (rows `done` appends) and `_Telemetry/history/*.jsonl` (one row per day and area) take git's
--- built-in `union`: every side's lines stay.
---
--- Key responsibilities:
---  - `driver`: the merge itself (a file of the three versions in, `%A` out)
---  - `install` / `status`: the driver in the repository's git configuration (it is not part of the repository)
---    and the lines in the vault's `.gitattributes`
---
--- Not its job: rendering the index (`tasks_nvim.index`), or pushing (`tasks_nvim.vault_push`).

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

---The name of the driver in `merge.<name>.driver` and in `.gitattributes`.
M.NAME = "tasks-index"

---The lines the vault's `.gitattributes` needs, in this order.
M.ATTRIBUTES = {
  "*/ROADMAP/TASKS.md merge=" .. M.NAME,
  "*/Backlog/README.md merge=union",
  "_Telemetry/history/*.jsonl merge=union",
}

---@param dir string
---@param args string[]
---@return string|nil stdout
---@return string|nil err
local function git(dir, args)
  local res = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  if res.code ~= 0 then
    return nil, ("git %s: %s"):format(args[1], vim.trim(res.stderr or ""))
  end
  return vim.trim(res.stdout or "")
end

---The merge: `ours` (git's `%A`) is overwritten with the three-way merge when it is free of conflicts, and left as
---it is otherwise. Always succeeds when the files can be read and written.
---@param ancestor string  `%O`
---@param ours string  `%A`, the result goes here
---@param theirs string  `%B`
---@return "merged"|"kept-ours"|nil result
---@return string|nil err
function M.driver(ancestor, ours, theirs)
  local before = fsio.read(ours)
  if not before then
    return nil, "cannot read " .. ours
  end
  local work = vim.fn.tempname()
  if not fsio.write_atomic(work, before) then
    return nil, "cannot write " .. work
  end
  -- exit code = number of conflicts (>= 127: an error); the file is merged in place
  local res = vim
    .system({ "git", "merge-file", "-q", work, ancestor, theirs }, { text = true })
    :wait()
  local result = "kept-ours"
  if res.code == 0 then
    local merged = fsio.read(work)
    if merged and fsio.write_atomic(ours, merged) then
      result = "merged"
    end
  end
  os.remove(work)
  return result
end

---The command git runs for the driver: this checkout's `scripts/tasks.lua` under the Neovim that runs now.
---@return string
function M.command()
  local here = fsio.norm(debug.getinfo(1, "S").source:sub(2))
  local script = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))) .. "/scripts/tasks.lua"
  local nvim = fsio.norm(vim.v.progpath)
  return ('"%s" --headless -u NONE -l "%s" merge-driver %%O %%A %%B %%P'):format(nvim, script)
end

---@param text string|nil
---@return string[] missing  the lines of `M.ATTRIBUTES` the text lacks
local function missing_lines(text)
  local have = {}
  for line in fsio.lf(text or ""):gmatch("[^\n]+") do
    have[vim.trim(line)] = true
  end
  local out = {}
  for _, l in ipairs(M.ATTRIBUTES) do
    if not have[l] then
      out[#out + 1] = l
    end
  end
  return out
end

---@param o? { root?: string }
---@return { state: "installed"|"outdated"|"absent", attributes: boolean, file: string, command: string|nil }|nil
---@return string|nil err
function M.status(o)
  local root, rerr = vault.root(o or {})
  if not root then
    return nil, rerr
  end
  local file = root .. "/.gitattributes"
  local cmd = git(root, { "config", "--get", "merge." .. M.NAME .. ".driver" })
  local state = "absent"
  if cmd and cmd ~= "" then
    state = cmd == M.command() and "installed" or "outdated"
  end
  local text = fsio.is_file(file) and fsio.read(file) or nil
  return {
    state = state --[[@as "installed"|"outdated"|"absent"]],
    attributes = #missing_lines(text) == 0,
    file = file,
    command = cmd,
  }
end

---Write the driver into the git configuration of the vault's repository and add the missing lines to its
---`.gitattributes` (not committed: the file belongs to the vault).
---@param o? { root?: string }
---@return { driver: "installed"|"unchanged"|"updated", added: string[], file: string }|nil
---@return string|nil err
function M.install(o)
  local st, err = M.status(o)
  if not st then
    return nil, err
  end
  local root = vault.root(o or {}) --[[@as string]]
  local _, e1 = git(root, { "config", "merge." .. M.NAME .. ".driver", M.command() })
  if e1 then
    return nil, e1
  end
  local _, e2 = git(root, { "config", "merge." .. M.NAME .. ".name", "tasks.nvim generated index" })
  if e2 then
    return nil, e2
  end
  local text = fsio.is_file(st.file) and fsio.read(st.file) or ""
  local missing = missing_lines(text)
  if #missing > 0 then
    local sep = (text == "" or text:sub(-1) == "\n") and "" or "\n"
    if not fsio.write_atomic(st.file, text .. sep .. table.concat(missing, "\n") .. "\n") then
      return nil, "cannot write " .. st.file
    end
  end
  return {
    driver = st.state == "installed" and "unchanged"
      or (st.state == "outdated" and "updated" or "installed"),
    added = missing,
    file = st.file,
  }
end

return M
