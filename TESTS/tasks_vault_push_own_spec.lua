-- TESTS/tasks_vault_push_own_spec.lua -- `tasks push` without a sha: only own commits the remote does not have by patch;
-- a pick the pre-commit hook refuses for a stale TASKS.md gets its index rendered anew; one that cannot be picked is
-- skipped and named while the others still go out.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local R =
    dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/vault_remote_fixture.lua")(H)
  local git, run, setup_remote, add_task, remote_indexes_fresh =
    R.git, R.run, R.setup_remote, R.add_task, R.remote_indexes_fresh

  -- 1. The pre-commit hook refuses the pick of a commit with a stale TASKS.md: its index is rendered anew ------------
  do
    local root, other, bare = setup_remote()
    -- the commit's TASKS.md is stale (made before the hook), and the remote moved in the same area, so the pick
    -- conflicts in TASKS.md and its --continue meets the hook
    F.task(H, root, "lib.nvim", "stale", F.meta("stale", "open"))
    git(root, { "add", "--", "lib.nvim/ROADMAP/tasks/stale.md" })
    H.write(
      root .. "/lib.nvim/ROADMAP/TASKS.md",
      H.read(root .. "/lib.nvim/ROADMAP/TASKS.md"):gsub("\n$", "\nhand edit\n")
    )
    git(root, { "add", "--", "lib.nvim/ROADMAP/TASKS.md" })
    git(root, { "commit", "-q", "-m", "stale index" })
    local mine = add_task(root, "cascade.nvim", "mine")
    add_task(other, "lib.nvim", "theirs")
    git(other, { "push", "-q", "origin", "main" })
    local installed = require("tasks_nvim.vault_hook").install({ root = root })
    ok(installed, "the vault's pre-commit hook is installed")

    local code, said = run(root, { "push", "--no-sync" })
    eq(code, 0, "push: " .. said)
    ok(said:find("carried a stale index: rendered lib.nvim anew", 1, true), "says so: " .. said)
    ok(not said:find("\nskipped\t", 1, true), "nothing skipped: " .. said)
    local check = remote_indexes_fresh(bare, "hook")
    ok(H.read(check .. "/lib.nvim/ROADMAP/tasks/stale.md"), "the stale commit went out")
    ok(
      H.read(check .. "/cascade.nvim/ROADMAP/tasks/mine.md"),
      "and the next one: " .. mine:sub(1, 9)
    )
    ok(
      not H.read(check .. "/lib.nvim/ROADMAP/TASKS.md"):find("hand edit", 1, true),
      "no hand edit left"
    )
  end

  -- 2. One commit cannot be picked (a conflict in a task file): it is skipped and named, the others go out ----------
  do
    local root, other, bare = setup_remote()
    ---Both sides edit the same task file and commit it with their index.
    local function edit_keep(dir, title)
      H.write(dir .. "/lib.nvim/ROADMAP/tasks/keep.md", F.text(F.meta(title, "open")))
      ok(require("tasks_nvim.index").write_area("lib.nvim", { root = dir }), "index of " .. title)
      git(dir, { "commit", "-q", "-am", "edit " .. title })
    end
    edit_keep(root, "Keep mine")
    local clash = git(root, { "rev-parse", "HEAD" })
    local mine = add_task(root, "cascade.nvim", "mine")
    edit_keep(other, "Keep theirs")
    git(other, { "push", "-q", "origin", "main" })

    local code, said = run(root, { "push", "--no-sync" })
    eq(code, 0, "the others go out: " .. said)
    ok(said:find("skipped\t" .. clash:sub(1, 9), 1, true), "the clash is named: " .. said)
    ok(said:find("lib.nvim/ROADMAP/tasks/keep.md", 1, true), "with its file: " .. said)
    local check = remote_indexes_fresh(bare, "skip")
    ok(H.read(check .. "/cascade.nvim/ROADMAP/tasks/mine.md"), "mine went out: " .. mine:sub(1, 9))
    ok(H.read(check .. "/lib.nvim/ROADMAP/tasks/keep.md"):find("theirs", 1, true), "theirs stays")
    ok(git(root, { "rev-list", "origin/main..HEAD" }):find(clash, 1, true), "the clash stays local")
  end

  -- 3. A local original of a commit already pushed by its sha, and another author's commit: left out ---------------
  do
    local root, other, bare = setup_remote()
    local first = add_task(root, "lib.nvim", "first")
    -- the remote moves first, so the push makes a new commit with the same patch
    add_task(other, "cascade.nvim", "elsewhere")
    git(other, { "push", "-q", "origin", "main" })
    local code, said = run(root, { "push", first, "--no-sync" })
    eq(code, 0, "push first: " .. said)
    git(root, { "fetch", "-q" })
    local _, anc = git(root, { "merge-base", "--is-ancestor", first, "origin/main" })
    ok(anc ~= 0, "(the local original is not on the remote, only its patch)")

    F.task(H, root, "lib.nvim", "guest", F.meta("guest", "open"))
    require("tasks_nvim.index").write_area("lib.nvim", { root = root })
    git(root, { "add", "--", "lib.nvim" })
    git(root, { "-c", "user.email=guest@example.org", "commit", "-q", "-m", "guest" })
    local guest = git(root, { "rev-parse", "HEAD" })
    local second = add_task(root, "cascade.nvim", "second")

    code, said = run(root, { "push", "--dry-run" })
    eq(code, 0, said)
    ok(said:find("left-out\t" .. first:sub(1, 9) .. "\tits patch is on", 1, true), said)
    ok(said:find("left-out\t" .. guest:sub(1, 9) .. "\tanother author", 1, true), said)
    ok(said:find("would-push\t" .. second:sub(1, 9), 1, true), said)
    ok(
      not said:find("would-push\t" .. first:sub(1, 9), 1, true),
      "the landed one is not picked again"
    )

    code, said = run(root, { "push", "--no-sync" })
    eq(code, 0, said)
    local check = remote_indexes_fresh(bare, "own")
    ok(H.read(check .. "/cascade.nvim/ROADMAP/tasks/second.md"), "the own commit went out")
    ok(
      not vim.uv.fs_stat(check .. "/lib.nvim/ROADMAP/tasks/guest.md"),
      "the other author's did not"
    )
  end
end
