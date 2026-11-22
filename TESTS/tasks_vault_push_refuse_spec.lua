-- TESTS/tasks_vault_push_refuse_spec.lua -- `tasks push`: a conflict in a file that is not generated, named commits only, a refusing hook.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local R =
    dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/vault_remote_fixture.lua")(H)
  local git, run, setup_remote, add_task, remote_indexes_fresh =
    R.git, R.run, R.setup_remote, R.add_task, R.remote_indexes_fresh

  -- 3. A conflict in a file that is not generated: nothing is pushed, the file is named -------------------------------
  do
    local root, other, bare = setup_remote()
    local before = git(bare, { "rev-parse", "main" })
    H.write(root .. "/lib.nvim/ROADMAP/tasks/keep.md", F.text(F.meta("Keep mine", "open")))
    git(root, { "commit", "-q", "-am", "edit keep" })
    H.write(other .. "/lib.nvim/ROADMAP/tasks/keep.md", F.text(F.meta("Keep theirs", "open")))
    git(other, { "commit", "-q", "-am", "edit keep elsewhere" })
    git(other, { "push", "-q", "origin", "main" })
    local theirs = git(bare, { "rev-parse", "main" })
    local code, said = run(root, { "push" })
    eq(code, 1, "refused: " .. said)
    ok(said:find("lib.nvim/ROADMAP/tasks/keep.md", 1, true), "names the file: " .. said)
    eq(git(bare, { "rev-parse", "main" }), theirs, "the remote is as the other session left it")
    ok(before ~= theirs, "(the other session did push)")
    eq(
      select(2, git(root, { "worktree", "list", "--porcelain" }):gsub("worktree ", "")),
      1,
      "worktree removed"
    )
  end

  -- 4. Pushing named commits only, and a hook that refuses ------------------------------------------------------------
  do
    local root, _, bare = setup_remote()
    local first = add_task(root, "lib.nvim", "first")
    local second = add_task(root, "cascade.nvim", "second")
    local code, said = run(root, { "push", first, "--no-sync" })
    eq(code, 0, "push first: " .. said)
    local check = remote_indexes_fresh(bare, "four")
    ok(H.read(check .. "/lib.nvim/ROADMAP/tasks/first.md"), "the named commit went out")
    ok(
      not vim.uv.fs_stat(check .. "/cascade.nvim/ROADMAP/tasks/second.md"),
      "the other one did not"
    )
    ok(
      git(root, { "rev-list", "origin/main..HEAD" }):find(second, 1, true),
      "it is still local (--no-sync)"
    )

    local hook = git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
      .. "/hooks/pre-push"
    H.write(hook, "#!/bin/sh\necho refused-by-hook >&2\nexit 1\n")
    vim.uv.fs_chmod(hook, tonumber("755", 8))
    code, said = run(root, { "push" })
    eq(code, 1, "a refusing hook ends the push")
    ok(said:find("refused-by-hook", 1, true), "with its words, no retry loop: " .. said)
  end

  -- 5. A pick that cannot be committed (signing fails) is an error, never "pushed" ------------------------------------
  do
    local root, other, bare = setup_remote()
    add_task(root, "lib.nvim", "unsigned")
    -- the remote has moved on, so the pick has to make a new commit (it cannot reuse the old one)
    add_task(other, "cascade.nvim", "elsewhere")
    git(other, { "push", "-q", "origin", "main" })
    local before = git(bare, { "rev-parse", "main" })
    local signer = H.tmpdir() .. "/failing-gpg.sh"
    H.write(signer, "#!/bin/sh\necho signing-is-broken >&2\nexit 1\n")
    vim.uv.fs_chmod(signer, tonumber("755", 8))
    git(root, { "config", "commit.gpgsign", "true" })
    -- whatever format the machine uses, its signing program is this one
    for _, key in ipairs({ "gpg.program", "gpg.ssh.program" }) do
      git(root, { "config", key, signer })
    end
    git(root, { "config", "gpg.format", "ssh" })
    git(root, { "config", "user.signingkey", signer })
    local code, said = run(root, { "push", "--no-sync" })
    eq(code, 1, "a failed commit ends the push: " .. said)
    ok(not said:find("pushed", 1, true), "and nothing is reported as pushed: " .. said)
    ok(said:find("could not be committed", 1, true), "the reason is named: " .. said)
    eq(git(bare, { "rev-parse", "main" }), before, "the remote did not move")
  end
end
