-- TESTS/tasks_ops_gitbusy_spec.lua -- every writing operation of tasks-ops/1 waits for git like `done` does
-- (another session's pull with an autostash rewrites the tree): `locked` and nothing written, or the write goes through.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local gitbusy = require("tasks_nvim.gitbusy")
  local ops = require("tasks_nvim.ops")
  local scan = require("tasks_nvim.scan")

  local real_sleep = gitbusy.sleep_until

  local root = F.vault(H)
  vim.fn.mkdir(root .. "/.git", "p")
  local alpha = F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "open", { { "prio", "2" } }))

  ---@param list table[]
  ---@param opts? table
  ---@param extra? table
  ---@return table entry  # the only result
  local function one(list, opts, extra)
    local doc, err = ops.run(
      vim.tbl_extend("force", { ops = list }, extra or {}),
      vim.tbl_extend("force", { root = root, today = F.TODAY, git_wait_ms = 0 }, opts or {})
    )
    assert(doc, vim.inspect(err))
    eq(#doc.results, 1, vim.inspect(doc))
    return doc.results[1]
  end

  local set = { { op = "set", id = "lib.nvim/alpha", patch = { prio = 1 } } }

  -- ── a rebase runs: the write says `locked` (retryable) and touches nothing ──
  vim.fn.mkdir(root .. "/.git/rebase-merge", "p")
  H.write(root .. "/.git/rebase-merge/autostash", "0123abcd\n")
  local before = H.read(alpha)
  local locked = one(set)
  eq(
    { locked.ok, locked.error.code, locked.error.retryable },
    { false, "locked", true },
    vim.inspect(locked)
  )
  has(locked.error.message, "git is rewriting the vault")
  eq(H.read(alpha), before, "the file is as it was")
  eq(scan.find("lib.nvim/alpha", { root = root }).prio, 2)

  -- ── a dry run writes nothing, so it does not wait ──
  local dry = one(set, nil, { dry_run = true })
  ok(dry.ok, vim.inspect(dry))
  eq(H.read(alpha), before, "a dry run changes nothing")

  -- ── a read does not wait (the hub asks often) ──
  local waits = 0
  local real_wait = gitbusy.wait
  gitbusy.wait = function(...)
    waits = waits + 1
    return real_wait(...)
  end
  api.call("list", vim.json.encode({}), { root = root, today = F.TODAY })
  gitbusy.wait = real_wait
  eq(waits, 0, "a read never looks at git")

  -- ── git ends while the write waits: it goes through ──
  gitbusy.sleep_until = function(_, cond)
    vim.fn.delete(root .. "/.git/rebase-merge", "rf")
    cond()
  end
  local through = one(set, { git_wait_ms = 1000 })
  gitbusy.sleep_until = real_sleep
  ok(through.ok, vim.inspect(through))
  eq(scan.find("lib.nvim/alpha", { root = root }).prio, 1, "the write was made once git was done")
end
