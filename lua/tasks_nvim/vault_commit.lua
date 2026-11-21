---@module 'tasks_nvim.vault_commit'
---@brief `tasks commit`: commit only your own paths of a shared vault, with the generated files that go with them.
---@description
--- In a shared checkout the staging area belongs to every session at once. A plain `git commit` takes what another
--- session staged a moment ago; `git commit -- <paths>` takes the tree's version of the paths, and the tree's
--- `ROADMAP/TASKS.md` is built from every session's tasks. Both happened in the tasks-vault (2026-11-21).
---
--- This commits from a staging area of its own (`GIT_INDEX_FILE`): `HEAD`, plus the paths as they are in the tree
--- (`git add -A`, so deletions and the moves of `done` count), plus what is generated from them, then moves `HEAD`
--- with a compare-and-swap. The shared staging area keeps everything else; only the committed paths are set to the
--- new `HEAD` there.
---
--- Key responsibilities:
---  - the `ROADMAP/TASKS.md` of every area the paths touch below `ROADMAP/`, rendered from the commit's own staging
---    area (`index.stage_area`)
---  - the `Backlog/README.md` of those areas: `HEAD`'s, plus the rows of the backlog files the commit adds (taken from
---    the tree's README, where `done` wrote them), minus those it removes; rows of another session's `done` stay out
---  - the changed series files `_Telemetry/history/*.jsonl` (generated, merged by `union`, never another's work)
---  - a signed commit when `commit.gpgsign` is set (`commit-tree` does not read it by itself)
---
--- Not its job: pushing, or hooks (`commit-tree` runs none; the index it commits is the generated one).

local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local vault = require("tasks_nvim.vault")

local M = {}

---How often a commit is built again when `HEAD` moved in the meantime (another session committed).
M.ATTEMPTS = 3

---@param dir string
---@param args string[]
---@param o? { env?: table<string, string>, stdin?: string }
---@return string|nil stdout
---@return string|nil err
local function git(dir, args, o)
  o = o or {}
  local res = vim
    .system(vim.list_extend({ "git", "-C", dir }, args), { text = true, env = o.env, stdin = o.stdin })
    :wait()
  if res.code ~= 0 then
    return nil, ("git %s: %s"):format(args[1], vim.trim(res.stderr or ""))
  end
  return res.stdout or ""
end

---Run `fn` with `GIT_INDEX_FILE` set for this process, so every git the engine starts (`index.stage_area`) works on
---that staging area; it is put back whatever happens.
---@generic T
---@param file string
---@param fn fun(): T, string|nil
---@return T|nil
---@return string|nil err
local function with_index(file, fn)
  local before = vim.env.GIT_INDEX_FILE
  vim.env.GIT_INDEX_FILE = file
  local ran, a, b = pcall(fn)
  vim.env.GIT_INDEX_FILE = before
  if not ran then
    return nil, tostring(a)
  end
  return a, b
end

---@param out string
---@return string[]
local function nul_list(out)
  local list = {}
  for p in out:gmatch("[^%z]+") do
    list[#list + 1] = p
  end
  return list
end

local BUCKETS = { TASKS = true, FEATURES = true }

---A backlog entry the README lists: `<area>/Backlog/<bucket>/<file>.md` or a folder task's `<dir>/<dir>.md`.
---@param path string  relative to the vault
---@return { area: string, bucket: string, rel: string }|nil
local function backlog_entry(path)
  local area, bucket, rel = path:match("^([^/]+)/Backlog/([^/]+)/(.+%.md)$")
  if not area or not BUCKETS[bucket] then
    return nil
  end
  local dir, base = rel:match("^([^/]+)/([^/]+)%.md$")
  if not rel:find("/", 1, true) or (dir and dir == base) then
    return { area = area, bucket = bucket, rel = rel }
  end
  return nil
end

---The row the tree's README has for `rel` (written by `done`), or nil.
---@param tree_text string|nil
---@param bucket string
---@param rel string
---@return string|nil
local function tree_row(tree_text, bucket, rel)
  if not tree_text then
    return nil
  end
  local marker = ("(./%s/%s)"):format(bucket, rel)
  for line in fsio.lf(tree_text):gmatch("[^\n]+") do
    if line:sub(1, 1) == "|" and line:find(marker, 1, true) then
      return line
    end
  end
  return nil
end

---Bring the `Backlog/README.md` of each area with added or removed backlog entries in line with the commit, in the
---staging area `ctx.env` names.
---@param ctx { root: string, top: string, prefix: string, env: table<string, string> }
---@param changed string[]  paths relative to the vault that the commit changes
---@return string[]|nil readmes  the READMEs written (relative to the vault)
---@return string|nil err
local function update_readmes(ctx, changed)
  local by_area, order = {}, {}
  for _, path in ipairs(changed) do
    local entry = backlog_entry(path)
    if entry then
      if not by_area[entry.area] then
        by_area[entry.area] = {}
        order[#order + 1] = entry.area
      end
      local list = by_area[entry.area]
      list[#list + 1] = entry
    end
  end
  table.sort(order)
  local written = {}
  for _, area in ipairs(order) do
    local rel_readme = area .. "/Backlog/README.md"
    local repo_rel = ctx.prefix .. rel_readme
    local staged = git(ctx.top, { "show", ":" .. repo_rel }, { env = ctx.env })
    local tree_text = fsio.is_file(ctx.root .. "/" .. rel_readme)
        and fsio.read(ctx.root .. "/" .. rel_readme)
      or nil
    local text = staged or ("# %s -- Backlog\n\nFinished work of this area.\n"):format(area)
    for _, entry in ipairs(by_area[area]) do
      local blob = git(
        ctx.top,
        { "show", ":" .. ctx.prefix .. area .. "/Backlog/" .. entry.bucket .. "/" .. entry.rel },
        { env = ctx.env }
      )
      if blob then
        local row = tree_row(tree_text, entry.bucket, entry.rel)
        if not row then
          local task = model.parse_text(blob, {
            path = ctx.root .. "/" .. area .. "/Backlog/" .. entry.bucket .. "/" .. entry.rel,
            area = area,
            location = "backlog",
          })
          local date = entry.rel:match("(%d%d%d%d%-%d%d%-%d%d)_") or os.date("%Y-%m-%d") --[[@as string]]
          row = mutate.readme_row(entry.bucket, entry.rel, task, date)
        end
        text = mutate.readme_add_row(text, entry.bucket, entry.rel, row)
      else
        text = mutate.readme_remove_row(text, entry.bucket, entry.rel)
      end
    end
    if text ~= staged then
      local hash, herr = git(
        ctx.top,
        { "hash-object", "-w", "--stdin", "--path=" .. repo_rel },
        { env = ctx.env, stdin = text }
      )
      if not hash then
        return nil, herr
      end
      local _, uerr = git(ctx.top, {
        "update-index",
        "--add",
        "--cacheinfo",
        ("100644,%s,%s"):format(vim.trim(hash), repo_rel),
      }, { env = ctx.env })
      if uerr then
        return nil, uerr
      end
      written[#written + 1] = rel_readme
    end
  end
  return written
end

---@class Tasks.VaultCommitOpts
---@field root? string
---@field message string
---@field dry_run? boolean  # Build the commit's tree and say what it holds; commit nothing.

---@class Tasks.VaultCommitResult
---@field commit? string            # The new commit (nil in a dry run).
---@field paths string[]            # What the commit changes against its parent, relative to the repository.
---@field indexes Tasks.IndexResult[]  # The generated index of each area the paths touch below `ROADMAP/`.
---@field readmes string[]          # The Backlog READMEs it brought in line.
---@field tree_differs string[]     # Generated files whose copy in the tree is not the committed one.
---@field attempts integer
---@field settle_error? string      # The shared staging area could not be set to the new `HEAD` for these paths.

---Build the commit once on top of `head`.
---@param ctx { root: string, top: string, prefix: string }
---@param paths string[]
---@param head string
---@return { tree: string, indexes: Tasks.IndexResult[], readmes: string[] }|nil
---@return string|nil err
local function build(ctx, paths, head)
  local file = vim.fn.tempname() .. "-index"
  local env = { GIT_INDEX_FILE = file }
  local c = vim.tbl_extend("force", ctx, { env = env })
  local function run()
    local _, rerr = git(ctx.top, { "read-tree", head }, { env = env })
    if rerr then
      return nil, rerr
    end
    local specs = { "add", "-A", "--" }
    for _, p in ipairs(paths) do
      specs[#specs + 1] = ":(literal)" .. p
    end
    local _, aerr = git(ctx.root, specs, { env = env })
    if aerr then
      return nil, aerr
    end
    -- The series files are generated, merged by `union`, and nobody's own work: they go along when they changed.
    if fsio.is_dir(ctx.root .. "/_Telemetry/history") then
      git(ctx.root, { "add", "-A", "--", "_Telemetry/history" }, { env = env })
    end
    local diff, derr = git(
      ctx.top,
      { "diff", "--cached", "--name-only", "--no-renames", "-z", head, "--" },
      { env = env }
    )
    if not diff then
      return nil, derr
    end
    local changed = {}
    for _, p in ipairs(nul_list(diff)) do
      if p:sub(1, #ctx.prefix) == ctx.prefix then
        changed[#changed + 1] = p:sub(#ctx.prefix + 1)
      end
    end
    local readmes, merr = update_readmes(c, changed)
    if not readmes then
      return nil, merr
    end
    local indexes, ierr = with_index(file, function()
      local areas, serr = index.staged_areas({ root = ctx.root })
      if not areas then
        return nil, serr
      end
      local out = {}
      for _, area in ipairs(areas) do
        local res, err = index.stage_area(area, { root = ctx.root })
        if not res then
          return nil, area .. ": " .. tostring(err)
        end
        out[#out + 1] = res
      end
      return out
    end)
    if not indexes then
      return nil, ierr
    end
    local tree, terr = git(ctx.top, { "write-tree" }, { env = env })
    if not tree then
      return nil, terr
    end
    return { tree = vim.trim(tree), indexes = indexes, readmes = readmes }
  end
  local ran, res, err = pcall(run)
  vim.fn.delete(file)
  if not ran then
    return nil, tostring(res)
  end
  return res, err
end

---Set the committed `paths` of the shared staging area to `HEAD`, so they do not read as staged changes; another
---session may hold its lock for a moment.
---@param top string
---@param paths string[]  relative to the repository
---@return string|nil err
local function settle_shared_index(top, paths)
  if #paths == 0 then
    return nil
  end
  local args = { "reset", "-q", "--" }
  for _, p in ipairs(paths) do
    args[#args + 1] = ":(top,literal)" .. p
  end
  local err
  for _ = 1, 5 do
    local _, rerr = git(top, args)
    if not rerr then
      return nil
    end
    err = rerr
    vim.wait(200)
  end
  return err
end

---Commit `paths` (relative to the vault; files or folders, also deleted ones) and what is generated from them.
---@param paths string[]
---@param opts Tasks.VaultCommitOpts
---@return Tasks.VaultCommitResult|nil
---@return string|nil err
function M.commit(paths, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if #paths == 0 then
    return nil, "commit needs at least one path"
  end
  if not opts.message or vim.trim(opts.message) == "" then
    return nil, "commit needs a message (--message=<text>)"
  end
  for _, p in ipairs(paths) do
    -- Relative to the vault and inside it: a path that climbs out would commit another repository's files.
    if p:match("^/") or p:match("^%a:") or p:find("\\", 1, true) then
      return nil, "give paths relative to the vault, with forward slashes: " .. p
    end
    for seg in p:gmatch("[^/]+") do
      if seg == ".." then
        return nil, "a path must stay inside the vault: " .. p
      end
    end
  end
  local top, terr = git(root, { "rev-parse", "--show-toplevel" })
  if not top then
    return nil, terr
  end
  local ctx = {
    root = root,
    top = fsio.norm(vim.trim(top)),
    prefix = vim.trim(git(root, { "rev-parse", "--show-prefix" }) or ""),
  }
  local sign = vim.trim(git(ctx.top, { "config", "--bool", "commit.gpgsign" }) or "") == "true"

  for attempt = 1, M.ATTEMPTS do
    local head, herr = git(ctx.top, { "rev-parse", "--verify", "HEAD" })
    if not head then
      return nil, herr
    end
    head = vim.trim(head)
    local built, berr = build(ctx, paths, head)
    if not built then
      return nil, berr
    end
    local head_tree = vim.trim(git(ctx.top, { "rev-parse", head .. "^{tree}" }) or "")
    if built.tree == head_tree then
      return nil, "nothing to commit: the paths and their generated files are as in HEAD"
    end
    local diff = git(
      ctx.top,
      { "diff-tree", "-r", "--name-only", "--no-renames", "-z", head, built.tree }
    ) or ""
    ---@type Tasks.VaultCommitResult
    local result = {
      paths = nul_list(diff),
      indexes = built.indexes,
      readmes = built.readmes,
      tree_differs = {},
      attempts = attempt,
    }
    -- The generated files are rendered from the commit, the tree's copies from every session's files: say where
    -- they part, so a `check` of the tree that calls one stale is no surprise.
    local generated = vim.deepcopy(built.readmes)
    for _, r in ipairs(built.indexes) do
      generated[#generated + 1] = r.path:sub(#ctx.prefix + 1)
    end
    for _, rel in ipairs(generated) do
      local repo_rel = ctx.prefix .. rel
      local in_tree = fsio.is_file(root .. "/" .. rel)
          and vim.trim(
            git(ctx.top, { "hash-object", "--path=" .. repo_rel, root .. "/" .. rel }) or ""
          )
        or nil
      local committed =
        git(ctx.top, { "rev-parse", "--verify", "--quiet", built.tree .. ":" .. repo_rel })
      committed = committed and vim.trim(committed) or nil
      if in_tree ~= committed then
        result.tree_differs[#result.tree_differs + 1] = rel
      end
    end
    if opts.dry_run then
      return result
    end
    local args = { "commit-tree", built.tree, "-p", head }
    if sign then
      args[#args + 1] = "-S"
    end
    local commit, cerr = git(ctx.top, args, { stdin = opts.message })
    if not commit then
      return nil, cerr
    end
    commit = vim.trim(commit)
    local subject = opts.message:match("^[^\n]*")
    local _, uerr =
      git(ctx.top, { "update-ref", "-m", "tasks commit: " .. subject, "HEAD", commit, head })
    if not uerr then
      result.commit = commit
      local serr = settle_shared_index(ctx.top, result.paths)
      if serr then
        result.settle_error = serr
      end
      return result
    end
    -- `HEAD` moved since it was read (another session committed): build again on top of the new one.
    local now = vim.trim(git(ctx.top, { "rev-parse", "--verify", "HEAD" }) or "")
    if now == head then
      return nil, uerr
    end
  end
  return nil, ("HEAD kept moving: gave up after %d attempts"):format(M.ATTEMPTS)
end

return M
