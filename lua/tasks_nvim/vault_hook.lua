---@module 'tasks_nvim.vault_hook'
---@brief The vault's pre-commit hook: a commit whose staged `ROADMAP/TASKS.md` is stale is refused.
---@description
--- In a shared vault a stale generated index that reaches `origin` blocks the pre-push gate of every session
--- (`index-stale`). The pre-push gate finds it only after the commit; this hook finds it at the commit, where the
--- session that made it can still fix it. It runs `tasks index --staged --check`, which reads only the areas with a
--- staged change below `ROADMAP/` (fast enough for every commit), against the staging area the commit writes
--- (`$GIT_INDEX_FILE`, so `git commit -- <paths>` is checked as it really is).
---
--- Key responsibilities:
---  - `script`: the hook's text, with the vault's place in its repository and this checkout as fallback
---  - `install`: write it to `<git-common-dir>/hooks/pre-commit` (shared by every linked worktree); a pre-commit hook
---    that is not this one is never overwritten
---  - `status`: `installed`, `outdated`, `absent` or `foreign`
---
--- Not its job: the check itself (`index.stage_area` with `check`), or `core.hooksPath` (a global hooks folder must
--- hand over to `.git/hooks`, as the one of `setup-claude-code` does).

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

---The second line of every hook this module writes: what tells it apart from somebody else's hook.
M.MARK = "# tasks.nvim pre-commit hook (tasks hook install)"

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

---The checkout of tasks.nvim this module belongs to (forward slashes).
---@return string
local function plugin_root()
  local here = fsio.norm(debug.getinfo(1, "S").source:sub(2))
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))
end

---A value for a single-quoted shell word.
---@param s string
---@return string
local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---The text of the hook.
---@param prefix string  the vault's folder in its repository (`""` or `sub/dir/`)
---@param fallback string  a tasks.nvim checkout to use when none is found next to the vault
---@return string
function M.script(prefix, fallback)
  local vault_dir = prefix == "" and '"$root"' or ('"$root"/' .. sh_quote(prefix:gsub("/$", "")))
  return table.concat({
    "#!/bin/sh",
    M.MARK,
    "# Refuses a commit whose staged <area>/ROADMAP/TASKS.md is not the one its staged task files render to",
    "# (`tasks index --staged --check`). Skip it once: git commit --no-verify.",
    'root="$(git rev-parse --show-toplevel)" || exit 1',
    'driver=""',
    'for dir in "${TASKS_NVIM_DIR:-}" "$root/.deps/tasks.nvim" "$root/../tasks.nvim" ' .. sh_quote(
      fallback
    ) .. "; do",
    '  if [ -n "$dir" ] && [ -f "$dir/scripts/tasks.lua" ]; then driver="$dir/scripts/tasks.lua"; break; fi',
    "done",
    'if [ -z "$driver" ]; then',
    '  echo "pre-commit: tasks.nvim not found (\\$TASKS_NVIM_DIR, ../tasks.nvim): the staged index is not checked" >&2',
    "  exit 0",
    "fi",
    "# The staging area this commit writes (`git commit -- <paths>` makes its own); git may name it relative to the",
    "# top level, where hooks run.",
    'case "${GIT_INDEX_FILE:-}" in',
    '"" | /* | [A-Za-z]:*) ;;',
    '*) GIT_INDEX_FILE="$root/$GIT_INDEX_FILE" && export GIT_INDEX_FILE ;;',
    "esac",
    'out="$(nvim -n -i NONE --headless -u NONE -l "$driver" --vault='
      .. vault_dir
      .. ' index --staged --check 2>&1)"',
    "rc=$?",
    '[ "$rc" -eq 0 ] && exit 0',
    'printf "%s\\n" "$out" >&2',
    "# 2 is a usage error: a tasks.nvim from before `index --staged --check` (an old checkout found first). That is",
    "# no verdict on the commit; refusing every commit of the vault for it would block all sessions.",
    'if [ "$rc" -eq 2 ]; then',
    '  echo "pre-commit: $driver does not know index --staged --check (update it): the staged index is not checked" >&2',
    "  exit 0",
    "fi",
    'echo "pre-commit: commit refused (exit $rc)" >&2',
    "exit 1",
    "",
  }, "\n")
end

---Where the hook of the vault `root` goes, and the vault's folder in its repository.
---@param root string
---@return { path: string, prefix: string, hooks_path: string|nil }|nil
---@return string|nil err
local function locate(root)
  local common, cerr = git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if not common then
    return nil, cerr
  end
  local prefix = git(root, { "rev-parse", "--show-prefix" }) or ""
  local hooks_path = git(root, { "config", "core.hooksPath" })
  return {
    path = fsio.norm(common) .. "/hooks/pre-commit",
    prefix = prefix,
    hooks_path = hooks_path ~= "" and hooks_path or nil,
  }
end

---@class Tasks.HookStatus
---@field state "installed"|"outdated"|"absent"|"foreign"
---@field path string               # the hook file
---@field hooks_path? string        # `core.hooksPath` when set: that folder must hand over to `path`

---@param opts? { root?: string }
---@return Tasks.HookStatus|nil
---@return string|nil err
function M.status(opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local where, lerr = locate(root)
  if not where then
    return nil, lerr
  end
  local status = { path = where.path, hooks_path = where.hooks_path, state = "absent" }
  if fsio.is_file(where.path) then
    local text = fsio.read(where.path) or ""
    if not text:find(M.MARK, 1, true) then
      status.state = "foreign"
    elseif fsio.lf(text) == M.script(where.prefix, plugin_root()) then
      status.state = "installed"
    else
      status.state = "outdated"
    end
  end
  return status
end

---Write the hook (or bring an older one of this module up to date). Another pre-commit hook is left alone.
---@param opts? { root?: string }
---@return Tasks.HookStatus|nil status  `state` is what it was before
---@return string|nil err
function M.install(opts)
  local status, err = M.status(opts)
  if not status then
    return nil, err
  end
  if status.state == "foreign" then
    return nil,
      ("%s is another pre-commit hook: not overwritten; add `tasks index --staged --check` to it by hand"):format(
        status.path
      )
  end
  if status.state == "installed" then
    return status
  end
  local root = vault.root(opts) --[[@as string]]
  local where = locate(root) --[[@as table]]
  vim.fn.mkdir(vim.fs.dirname(where.path), "p")
  local ok, werr = fsio.write_atomic(where.path, M.script(where.prefix, plugin_root()))
  if not ok then
    return nil, "cannot write " .. where.path .. ": " .. tostring(werr)
  end
  -- 0755: git runs only an executable hook (on Windows the shebang is what counts).
  vim.uv.fs_chmod(where.path, 493)
  return status
end

return M
