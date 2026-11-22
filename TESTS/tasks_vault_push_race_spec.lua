-- TESTS/tasks_vault_push_race_spec.lua -- `tasks push` when the remote moves while the push runs: rejected, fetched, pushed again.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local vault_push = require("tasks_nvim.vault_push")
  local R =
    dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/vault_remote_fixture.lua")(H)
  local git, setup_remote, add_task, remote_indexes_fresh =
    R.git, R.setup_remote, R.add_task, R.remote_indexes_fresh

  -- 2. The remote moves while the hook runs: rejected, then fetched and again -----------------------------------------
  do
    local root, other, bare = setup_remote()
    add_task(root, "cascade.nvim", "mine-two")
    add_task(other, "lib.nvim", "raced")
    -- the pre-push hook of the shared repository (worktrees use it too) pushes the other session's commit once,
    -- right before the first push goes out
    local marker = H.tmpdir() .. "/raced.once"
    local where = H.tmpdir() .. "/hook.pwd"
    H.write(
      git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" }) .. "/hooks/pre-push",
      ("#!/bin/sh\npwd > '%s'\nif [ ! -f '%s' ]; then : > '%s'; env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C '%s' push -q origin main; fi\nexit 0\n"):format(
        where,
        marker,
        marker,
        other
      )
    )
    vim.uv.fs_chmod(
      git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" }) .. "/hooks/pre-push",
      tonumber("755", 8)
    )
    local res, err = vault_push.push({ root = root, pause_ms = 10 })
    ok(res, "push: " .. tostring(err))
    eq(res.attempt, 2, "the second attempt got through")
    -- the gate runs in a folder next to the repository (a trusted root), never in the temp folder
    local ran_in = vim.trim(H.read(where))
    -- (compare the last two path parts: the shell may print `/c/...` where Lua has `C:/...`)
    local function tail2(p)
      return vim.fs.basename(vim.fs.dirname(p)) .. "/" .. vim.fs.basename(p)
    end
    eq(
      vim.fs.basename(vim.fs.dirname(ran_in)),
      vim.fs.basename(vim.fs.dirname(root)),
      "the hook ran next to the repository: " .. tail2(ran_in)
    )
    ok(vim.fs.basename(ran_in):find(".tasks-push-", 1, true), "in the throwaway folder: " .. ran_in)
    local check = remote_indexes_fresh(bare, "two")
    ok(H.read(check .. "/cascade.nvim/ROADMAP/tasks/mine-two.md"), "own task on the remote")
    ok(H.read(check .. "/lib.nvim/ROADMAP/tasks/raced.md"), "the raced task is still there")
  end
end
