---@module 'tasks_nvim.vault_push'
---@brief `tasks push`: push your own commits of a shared vault from a throwaway worktree, with retries.
---@description
--- In a vault many sessions share, `origin/main` moves every few seconds, the pre-push hook checks the working
--- tree of the shared checkout (every session's uncommitted files), and `git pull --rebase --autostash` ends in a
--- conflict in a generated `ROADMAP/TASKS.md`. More than a dozen pushes failed that way on 2026-11-21/22.
---
--- This puts the commits on a worktree of its own that sits on `origin/main`, so the hook (and `git push`) sees
--- only what goes out, never the files of another session:
---  1. `git worktree add --detach <next to the repository> origin/main` (a folder the pre-push gate trusts: it
---     refuses one in the temp folder)
---  2. cherry-pick the commits; a conflict in a generated file is solved, never merged by hand: `TASKS.md` is
---     rendered anew (`tasks index`), `Backlog/README.md` and the `_Telemetry/history/*.jsonl` series keep the
---     lines of both sides; a conflict in any other file ends the push and names the file
---  3. render the index of every area the commits touch; a changed `TASKS.md` is committed (`tasks: refresh index`)
---  4. `git push origin HEAD:main`; when the remote moved (rejected), fetch and start again, up to
---     `ATTEMPTS` times; any other refusal (the hook) ends it with git's words
---  5. bring the shared checkout to `origin/main` (`git rebase --autostash`): the pushed commits drop out, the
---     uncommitted files of other sessions stay; a generated file that conflicts with the stash is rendered anew
---     and the stash is dropped once everything else in it is in the tree
---  6. remove the worktree with `git worktree remove`; when that fails the path is reported, never `rm -rf`
---
--- Never `--no-verify`. Commits are signed when `commit.gpgsign` is set (the cherry-pick signs them).
---
--- Not its job: committing (`tasks_nvim.vault_commit`), or the merge driver (`tasks_nvim.vault_merge`).

local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local vault = require("tasks_nvim.vault")

local M = {}

---How often the push starts again after the remote moved.
M.ATTEMPTS = 5

---Milliseconds between two attempts.
M.PAUSE_MS = 700

---@class Tasks.PushResult
---@field pushed string[]  full SHAs as they are on the remote (the commits as cherry-picked, then the refresh)
---@field picked string[]  the local commits that went out
---@field attempt integer  the attempt that pushed
---@field head string|nil  the commit the remote has now
---@field notes string[]
---@field leftover string|nil  the worktree that could not be removed
---@field sync string  `synced`, `skipped (...)` or `failed: <why>`

---@param dir string
---@param args string[]
---@return string out
---@return string err
---@return integer code
local function run(dir, args)
  local res = vim
    .system(
      vim.list_extend({ "git", "-C", dir }, args),
      { text = true, env = { GIT_EDITOR = "true", GIT_TERMINAL_PROMPT = "0" } }
    )
    :wait()
  return vim.trim(res.stdout or ""), vim.trim(res.stderr or ""), res.code
end

---@param dir string
---@param args string[]
---@return string|nil out
---@return string|nil err
local function git(dir, args)
  local out, err, code = run(dir, args)
  if code ~= 0 then
    return nil, ("git %s: %s"):format(args[1], err ~= "" and err or out)
  end
  return out
end

---What a generated file of the vault is, from its path relative to the vault.
---@param rel string
---@return "index"|"union"|nil
local function generated_kind(rel)
  if rel:match("^[^/]+/ROADMAP/TASKS%.md$") then
    return "index"
  end
  if rel:match("^[^/]+/Backlog/README%.md$") or rel:match("^_Telemetry/history/[^/]+%.jsonl$") then
    return "union"
  end
  return nil
end
M.generated_kind = generated_kind

---@param s string
---@return string[]
local function lines_of(s)
  local list = {}
  for l in s:gmatch("[^\r\n]+") do
    list[#list + 1] = l
  end
  return list
end

---A path of the repository relative to the vault.
---@param prefix string
---@param f string
---@return string
local function rel_of(prefix, f)
  if prefix ~= "" and f:sub(1, #prefix) == prefix then
    return f:sub(#prefix + 1)
  end
  return f
end

---The vault's folder inside a checkout of its repository.
---@param top string
---@param prefix string
---@return string
local function vault_in(top, prefix)
  if prefix == "" then
    return top
  end
  return top .. "/" .. prefix:gsub("/$", "")
end

---Solve the unmerged generated files of a pick in `wt`.
---@param wt string
---@param prefix string
---@param areas table<string, boolean>  filled with the areas whose index must be rendered
---@param side "ours"|"theirs"  whose rendered index stays until it is rendered anew: the commit's (`theirs`, a
---  cherry-pick) or the branch's it is replayed on (`ours`, a rebase: the replayed commit may end up empty)
---@return string|nil bad  the first file that is no generated file or could not be solved
local function solve_conflicts(wt, prefix, areas, side)
  local out = git(wt, { "diff", "--name-only", "--diff-filter=U" }) or ""
  for _, f in ipairs(lines_of(out)) do
    local rel = rel_of(prefix, f)
    local kind = generated_kind(rel)
    if not kind then
      return f
    end
    if kind == "index" then
      areas[rel:match("^([^/]+)/")] = true
      local _, _, code = run(wt, { "checkout", "--" .. side, "--", f })
      if code ~= 0 then
        -- deleted on one side: nothing of it to keep, the index of the area is rendered anew
        local _, _, rm = run(wt, { "rm", "-q", "--", f })
        if rm ~= 0 then
          return f
        end
      else
        run(wt, { "add", "--", f })
      end
    else
      local base, ours, theirs = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
      local function stage(n)
        local s = run(wt, { "show", (":%d:%s"):format(n, f) })
        return s ~= "" and (s .. "\n") or ""
      end
      local ok = fsio.write_atomic(base, stage(1))
        and fsio.write_atomic(ours, stage(2))
        and fsio.write_atomic(theirs, stage(3))
      local merged
      if ok then
        local res = vim
          .system({ "git", "merge-file", "-p", "--union", ours, base, theirs }, { text = true })
          :wait()
        merged = res.code >= 0 and res.code < 127 and res.stdout or nil
      end
      os.remove(base)
      os.remove(ours)
      os.remove(theirs)
      if not merged or not fsio.write_atomic(wt .. "/" .. f, merged) then
        return f
      end
      run(wt, { "add", "--", f })
    end
  end
  return nil
end

---A pick without conflicts that still has to be committed (or that `--continue` just failed to commit). Only a
---pick that leaves nothing staged is skipped (the remote has the change already); any other failure (signing, a
---hook, a lock) is an error, never a silent skip.
---@param wt string
---@param sha string
---@param continued boolean|nil  `--continue` was already tried
---@return boolean ok
---@return string|nil err
local function finish_pick(wt, sha, continued)
  local err, code
  if not continued then
    local _, e, c = run(wt, { "cherry-pick", "--continue" })
    err, code = e, c
    if code == 0 then
      return true
    end
  end
  local _, _, staged = run(wt, { "diff", "--cached", "--quiet" })
  if staged == 0 then
    run(wt, { "cherry-pick", "--skip" })
    return true
  end
  local text = err
  if not text or text == "" then
    local _, e2 = git(wt, { "cherry-pick", "--continue" })
    text = e2 or "git cherry-pick --continue failed"
  end
  run(wt, { "cherry-pick", "--abort" })
  return false, ("cherry-pick of %s could not be committed: %s"):format(sha:sub(1, 9), text)
end

---Cherry-pick `sha` onto the worktree's HEAD.
---@param wt string
---@param prefix string
---@param sha string
---@param areas table<string, boolean>
---@return boolean ok
---@return string|nil err
local function pick(wt, prefix, sha, areas)
  local _, _, code = run(wt, { "cherry-pick", sha })
  if code == 0 then
    return true
  end
  for _ = 1, 8 do
    local unmerged = git(wt, { "diff", "--name-only", "--diff-filter=U" }) or ""
    if unmerged == "" then
      return finish_pick(wt, sha)
    end
    local bad = solve_conflicts(wt, prefix, areas, "theirs")
    if bad then
      run(wt, { "cherry-pick", "--abort" })
      return false, ("conflict in %s (not a generated file; solve it and push again)"):format(bad)
    end
    local _, _, c = run(wt, { "cherry-pick", "--continue" })
    if c == 0 then
      return true
    end
    if (git(wt, { "diff", "--name-only", "--diff-filter=U" }) or "") == "" then
      return finish_pick(wt, sha, true)
    end
  end
  run(wt, { "cherry-pick", "--abort" })
  return false, "cherry-pick of " .. sha:sub(1, 9) .. " did not settle"
end

---Render the index of the areas the commits touch; commit what changed.
---@param wt string
---@param prefix string
---@param base string  the remote branch the commits sit on
---@param areas table<string, boolean>
---@return string|nil err
local function refresh_index(wt, prefix, base, areas)
  local root = vault_in(wt, prefix)
  local names = git(wt, { "diff", "--name-only", base, "HEAD" }) or ""
  for _, f in ipairs(lines_of(names)) do
    local area = rel_of(prefix, f):match("^([^/]+)/")
    if area and vault.has_area(root, area) then
      areas[area] = true
    end
  end
  local paths = {}
  for area in pairs(areas) do
    if vault.has_area(root, area) then
      local ok, err = index.write_area(area, { root = root })
      if not ok then
        return ("index of %s: %s"):format(area, tostring(err))
      end
      paths[#paths + 1] = prefix .. area .. "/ROADMAP/TASKS.md"
    end
  end
  table.sort(paths)
  local changed = {}
  for _, p in ipairs(paths) do
    if run(wt, { "status", "--porcelain", "--", p }) ~= "" then
      changed[#changed + 1] = p
    end
  end
  if #changed == 0 then
    return nil
  end
  local _, aerr = git(wt, vim.list_extend({ "add", "--" }, changed))
  if aerr then
    return aerr
  end
  local _, cerr =
    git(wt, vim.list_extend({ "commit", "-q", "-m", "tasks: refresh index", "--" }, changed))
  return cerr
end

local RETRY = {
  "rejected",
  "non%-fast%-forward",
  "fetch first",
  "failed to update ref",
  "cannot lock ref",
  "stale info",
}

---@param err string
---@return boolean
local function retryable(err)
  local low = err:lower()
  for _, p in ipairs(RETRY) do
    if low:find(p) then
      return true
    end
  end
  return false
end

---After the push: the shared checkout onto `remote_ref`, the files of other sessions left as they are.
---@param top string
---@param prefix string
---@param remote_ref string
---@param notes string[]
---@return string sync
local function sync_checkout(top, prefix, remote_ref, notes)
  if run(top, { "symbolic-ref", "-q", "--short", "HEAD" }) == "" then
    return "skipped (detached HEAD)"
  end
  local stash_before = run(top, { "rev-parse", "-q", "--verify", "refs/stash" })
  local _, err, code = run(top, { "rebase", "--autostash", remote_ref })
  -- A local commit that went out is replayed too when the push changed it (the rendered index): a conflict in a
  -- generated file is solved as in the push, the commit that ends up empty is skipped.
  for _ = 1, 30 do
    if code == 0 or run(top, { "rev-parse", "-q", "--verify", "REBASE_HEAD" }) == "" then
      break
    end
    if solve_conflicts(top, prefix, {}, "ours") then
      break
    end
    _, err, code = run(top, { "rebase", "--continue" })
    if code ~= 0 and (git(top, { "diff", "--name-only", "--diff-filter=U" }) or "") == "" then
      _, err, code = run(top, { "rebase", "--skip" })
    end
  end
  local stash_after = run(top, { "rev-parse", "-q", "--verify", "refs/stash" })
  local root = vault_in(top, prefix)
  local unmerged = lines_of(run(top, { "diff", "--name-only", "--diff-filter=U" }))
  if #unmerged > 0 then
    local rest = {}
    for _, f in ipairs(unmerged) do
      local rel = rel_of(prefix, f)
      if
        generated_kind(rel) == "index" and index.write_area(rel:match("^([^/]+)/"), { root = root })
      then
        -- the tree keeps the rendered file as an uncommitted change, as it had before
        run(top, { "add", "--", f })
        run(top, { "reset", "-q", "--", f })
      else
        rest[#rest + 1] = f
      end
    end
    if #rest > 0 then
      if run(top, { "rev-parse", "-q", "--verify", "REBASE_HEAD" }) ~= "" then
        run(top, { "rebase", "--abort" })
      end
      return "failed: conflict in " .. table.concat(rest, ", ")
    end
  elseif code ~= 0 then
    run(top, { "rebase", "--abort" })
    return "failed: " .. (err ~= "" and err or "rebase")
  end
  if stash_after ~= "" and stash_after ~= stash_before then
    -- git left the autostash behind (it could not apply it cleanly): drop it only when its files are in the tree
    local plain = {}
    for _, f in ipairs(lines_of(run(top, { "stash", "show", "--name-only", "stash@{0}" }))) do
      if not generated_kind(rel_of(prefix, f)) then
        plain[#plain + 1] = f
      end
    end
    local same = true
    if #plain > 0 then
      local _, _, dc = run(top, vim.list_extend({ "diff", "--quiet", "stash@{0}", "--" }, plain))
      same = dc == 0
    end
    if same then
      run(top, { "stash", "drop", "-q" })
    else
      notes[#notes + 1] =
        "the autostash differs from the tree and stays: git stash show -p stash@{0}"
    end
  end
  return "synced"
end

---Push local commits of the vault's repository to `origin/main` from a throwaway worktree.
---@param o? { root?: string, shas?: string[], attempts?: integer, remote?: string, branch?: string, sync?: boolean, pause_ms?: integer, dry_run?: boolean }
---@return Tasks.PushResult|nil
---@return string|nil err
function M.push(o)
  o = o or {}
  local root, rerr = vault.root(o)
  if not root then
    return nil, rerr
  end
  local top, terr = git(root, { "rev-parse", "--show-toplevel" })
  if not top then
    return nil, terr
  end
  top = fsio.norm(top)
  local prefix = git(root, { "rev-parse", "--show-prefix" }) or ""
  local remote, branch = o.remote or "origin", o.branch or "main"
  local remote_ref = remote .. "/" .. branch
  local _, ferr = git(top, { "fetch", "-q", remote, branch })
  if ferr then
    return nil, ferr
  end
  local list = {}
  if o.shas and #o.shas > 0 then
    for _, s in ipairs(o.shas) do
      local full, e = git(top, { "rev-parse", "--verify", s .. "^{commit}" })
      if not full then
        return nil, e
      end
      list[#list + 1] = full
    end
  else
    list =
      lines_of(git(top, { "rev-list", "--reverse", "--no-merges", remote_ref .. "..HEAD" }) or "")
  end
  local todo = {}
  for _, s in ipairs(list) do
    local _, _, c = run(top, { "merge-base", "--is-ancestor", s, remote_ref })
    if c ~= 0 then
      todo[#todo + 1] = s
    end
  end
  ---@type Tasks.PushResult
  local res = { pushed = {}, picked = todo, attempt = 0, notes = {}, sync = "skipped" }
  if #todo == 0 or o.dry_run then
    return res
  end

  -- next to the repository, not in the temp folder: the pre-push gate runs the project's own specs and only does
  -- that in a folder it trusts (`TESTING_TRUST_ROOTS` lists the folder that holds the checkouts)
  local wt = ("%s/.tasks-push-%s-%x"):format(
    vim.fs.dirname(top),
    vim.fs.basename(top),
    vim.uv.hrtime() % 0xffffff
  )
  local _, werr = git(top, { "worktree", "add", "-q", "--detach", wt, remote_ref })
  if werr then
    return nil, werr
  end
  local fail
  for attempt = 1, o.attempts or M.ATTEMPTS do
    res.attempt = attempt
    fail = nil
    local _, e = git(wt, { "fetch", "-q", remote, branch })
    if e then
      fail = e
      break
    end
    run(wt, { "cherry-pick", "--abort" })
    git(wt, { "reset", "-q", "--hard", remote_ref })
    local areas, bad = {}, nil
    for _, s in ipairs(todo) do
      local ok, perr = pick(wt, prefix, s, areas)
      if not ok then
        bad = perr
        break
      end
    end
    if bad then
      fail = bad
      break
    end
    local ierr = refresh_index(wt, prefix, remote_ref, areas)
    if ierr then
      fail = ierr
      break
    end
    -- the list before the push: the push itself moves `remote_ref`
    local going = lines_of(run(wt, { "rev-list", "--reverse", remote_ref .. "..HEAD" }))
    if #going == 0 then
      -- every pick was skipped: the remote has all of it already
      res.head = run(wt, { "rev-parse", "HEAD" })
      res.notes[#res.notes + 1] = "nothing new landed: "
        .. res.head:sub(1, 9)
        .. " is already on "
        .. remote_ref
      break
    end
    local _, perr, pcode = run(wt, { "push", remote, "HEAD:" .. branch })
    if pcode == 0 then
      res.head = run(wt, { "rev-parse", "HEAD" })
      run(wt, { "fetch", "-q", remote, branch })
      local _, _, anc = run(wt, { "merge-base", "--is-ancestor", res.head, remote_ref })
      if anc ~= 0 then
        fail = "git push said ok, but " .. res.head:sub(1, 9) .. " is not on " .. remote_ref
        break
      end
      res.pushed = going
      break
    end
    if not retryable(perr) then
      fail = perr
      break
    end
    fail = ("the remote kept moving: %d attempt(s) rejected"):format(attempt)
    vim.uv.sleep(o.pause_ms or M.PAUSE_MS)
  end

  local _, _, rc = run(top, { "worktree", "remove", "--force", wt })
  if rc ~= 0 then
    res.leftover = wt
  end
  run(top, { "worktree", "prune" })
  if fail then
    return nil, fail .. (res.leftover and (" (worktree left at " .. wt .. ")") or "")
  end
  if o.sync ~= false then
    run(top, { "fetch", "-q", remote, branch })
    res.sync = sync_checkout(top, prefix, remote_ref, res.notes)
  end
  return res
end

return M
