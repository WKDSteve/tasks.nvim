-- TESTS/tasks_done_gitbusy_spec.lua -- `done` while git rewrites the vault (another session's pull with an autostash).

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local done_flow = require("tasks_nvim.done_flow")
  local gitbusy = require("tasks_nvim.gitbusy")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local contract = require("tasks_nvim.contract")
  local errors = require("lib.nvim.contract.errors")

  local real_busy, real_sleep = gitbusy.busy, gitbusy.sleep_until
  local function restore()
    gitbusy.busy, gitbusy.sleep_until = real_busy, real_sleep
  end

  -- ── git_dir: a .git folder, a .git file of a worktree, a vault below the root of its checkout ──
  local repo = H.tmpdir()
  vim.fn.mkdir(repo .. "/.git", "p")
  eq(gitbusy.git_dir(repo), repo .. "/.git")
  vim.fn.mkdir(repo .. "/docs/vault", "p")
  eq(gitbusy.git_dir(repo .. "/docs/vault"), repo .. "/.git", "a vault inside a checkout")
  local wt = H.tmpdir()
  H.write(wt .. "/.git", "gitdir: " .. repo .. "/.git/worktrees/wt\n")
  eq(
    gitbusy.git_dir(wt),
    repo .. "/.git/worktrees/wt",
    "a worktree: the folder its .git file names"
  )
  local rel = H.tmpdir()
  H.write(rel .. "/.git", "gitdir: ../elsewhere/.git\n")
  eq(
    gitbusy.git_dir(rel),
    rel .. "/../elsewhere/.git",
    "a relative gitdir is read from the checkout"
  )
  eq(gitbusy.busy(repo), nil, "an idle checkout")
  vim.fn.mkdir(repo .. "/.git/rebase-merge", "p")
  local what, where = gitbusy.busy(repo)
  has(what, "rebase")
  eq(where, repo .. "/.git/rebase-merge")
  vim.fn.delete(repo .. "/.git/rebase-merge", "rf")
  H.write(repo .. "/.git/index.lock", "")
  has(gitbusy.message(gitbusy.busy(repo)), "the lock is left over", "a stale lock is named as one")

  -- ── the vault of the finishes below is a checkout of its own ──
  local root = F.vault(H)
  vim.fn.mkdir(root .. "/.git", "p")
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp", git_wait_ms = 0 }

  -- ── a rebase runs: done finishes nothing and says why, as `locked` (retryable) ──
  local a = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Busy a" })))
  vim.fn.mkdir(root .. "/.git/rebase-merge", "p")
  H.write(root .. "/.git/rebase-merge/autostash", "0123abcd\n")
  local no, err, info = done_flow.run(a.id, o)
  eq(no, nil)
  has(err, "git is rewriting the vault")
  has(err, "rebase-merge")
  eq(info and info.code, "locked")
  ok(scan.find(a.id, { root = root }) ~= nil, "the task is still open")
  eq(scan.find_done(a.id, { root = root }), nil, "and nothing is in the Backlog")
  local classified = errors.classify(err, nil, { patterns = contract.ERROR_PATTERNS })
  eq(classified.code, "locked", "the contract names it locked")
  ok(classified.retryable, "and retryable")

  -- ── git ends while done waits: the finish goes through ──
  gitbusy.sleep_until = function(_, cond)
    vim.fn.delete(root .. "/.git/rebase-merge", "rf")
    cond()
  end
  local waited = assert(done_flow.run(a.id, vim.tbl_extend("force", o, { git_wait_ms = 1000 })))
  restore()
  ok(H.exists(waited.done.to), "finished once git was done")
  eq(waited.done.came_back, nil)
  eq(waited.notes, {})

  -- ── git starts during the finish and its autostash writes the open file back: said, not hidden ──
  local b = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Busy b" })))
  local open_path = scan.find(b.id, { root = root }).path
  local open_text = H.read(open_path) .. "\nA note the autostash brings back.\n"
  H.write(open_path, open_text)
  local calls = 0
  gitbusy.busy = function()
    calls = calls + 1
    if calls == 2 then
      -- the first look after the finish: the pull runs, and puts the stashed text back
      H.write(open_path, open_text)
      return "a rebase (or a pull with --rebase and --autostash)", root .. "/.git/rebase-merge"
    end
    return nil
  end
  local flow = assert(done_flow.run(b.id, o))
  restore()
  eq(flow.done.came_back, open_path, "the open file is back")
  has(flow.done.git_seen, "rebase")
  eq(flow.done.git_busy, nil, "git was done after the wait")
  local note = table.concat(flow.notes, "\n")
  has(note, "came back after the finish")
  has(note, "duplicate-id")
  ok(H.exists(flow.done.to), "the finished copy stays")

  -- ── git runs during the finish, is done after the wait, nothing came back: nothing to say ──
  local d = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Busy d" })))
  calls = 0
  gitbusy.busy = function()
    calls = calls + 1
    if calls == 2 then
      return "another git command (it holds index.lock)", root .. "/.git/index.lock"
    end
    return nil
  end
  local brief = assert(done_flow.run(d.id, o))
  restore()
  ok(brief.done.git_seen ~= nil, "git was seen after the finish")
  eq(brief.done.git_busy, nil)
  eq(brief.notes, {}, "no word about a git that is done")

  -- ── git still busy at the end, but nothing came back: a note to look ──
  local c = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Busy c" })))
  calls = 0
  gitbusy.busy = function()
    calls = calls + 1
    if calls >= 2 then
      return "another git command (it holds index.lock)", root .. "/.git/index.lock"
    end
    return nil
  end
  local still = assert(done_flow.run(c.id, o))
  restore()
  eq(still.done.came_back, nil)
  has(table.concat(still.notes, "\n"), "git was still busy")
end
