-- TESTS/tasks_vault_hook_spec.lua -- the vault's pre-commit hook (`tasks hook install`): installed into the
-- repository's hooks folder, never over another hook, and at `git commit` it refuses a stale staged index. It checks
-- the staging area that commit writes: also the private one of `git commit -- <paths>`.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")
  local vault_hook = require("tasks_nvim.vault_hook")

  local root = F.vault(H)

  ---@param args string[]
  ---@return string stdout
  ---@return integer code
  ---@return string stderr
  local function git(args)
    local res = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
    return res.stdout or "", res.code, res.stderr or ""
  end
  local ID = { "-c", "user.name=t", "-c", "user.email=t@example.org" }

  ---@param args string[]
  ---@return integer code
  ---@return string said  stdout and stderr, in order
  local function run(args)
    local said = {}
    local function put(s)
      said[#said + 1] = s
    end
    local code = cli.run(vim.list_extend(vim.deepcopy(args), { "--vault=" .. root }), {
      out = put,
      err = put,
    })
    return code, table.concat(said, "\n")
  end

  eq(select(2, git({ "init", "-q" })), 0, "git init")
  git({ "config", "core.autocrlf", "false" })
  F.task(H, root, "lib.nvim", "one", F.meta("One", "open"))
  ok(index.write_area("lib.nvim", { root = root }), "seed index")
  git({ "add", "." })
  eq(
    select(2, git(vim.list_extend(vim.deepcopy(ID), { "commit", "-q", "-m", "seed" }))),
    0,
    "seed commit"
  )
  local code, said

  -- The hook: installed into the repository's hooks folder, never over somebody else's.
  local st = vault_hook.status({ root = root })
  eq(st.state, "absent", "no hook yet")
  code, said = run({ "hook", "status" })
  eq(code, 1, "status of a missing hook exits 1: " .. said)
  code, said = run({ "hook", "install" })
  eq(code, 0, "install: " .. said)
  ok(said:find("^installed\t"), "says installed: " .. said)
  eq(vault_hook.status({ root = root }).state, "installed", "and it is")
  code, said = run({ "hook", "install" })
  ok(code == 0 and said:find("^unchanged\t"), "a second install changes nothing: " .. said)
  eq(run({ "hook", "frob" }), 2, "an unknown subcommand is a usage error")

  local hook_file = st.path
  local own = table.concat(vim.fn.readfile(hook_file), "\n")
  vim.fn.writefile({ "#!/bin/sh", "echo mine", "exit 0" }, hook_file)
  eq(vault_hook.status({ root = root }).state, "foreign", "another hook is foreign")
  code, said = run({ "hook", "install" })
  eq(code, 1, "and is not overwritten: " .. said)
  eq(vim.fn.readfile(hook_file)[2], "echo mine", "it is still there")
  vim.fn.writefile({ "#!/bin/sh", vault_hook.MARK, "exit 0" }, hook_file)
  eq(vault_hook.status({ root = root }).state, "outdated", "an older hook of ours is outdated")
  code, said = run({ "hook", "install" })
  ok(code == 0 and said:find("^updated\t"), "and is brought up to date: " .. said)
  eq(table.concat(vim.fn.readfile(hook_file), "\n"), own, "to the same text")

  -- The hook at work. `core.hooksPath` is pinned to the repository's own hooks folder: a global one (as on the
  -- workstations) would decide on its own whether to hand over.
  local hooks = vim.fs.dirname(hook_file)
  local commit =
    vim.list_extend(vim.deepcopy(ID), { "-c", "core.hooksPath=" .. hooks, "commit", "-q" })

  F.task(H, root, "lib.nvim", "four", F.meta("Four", "open"))
  git({ "add", "--", "lib.nvim/ROADMAP/tasks/four.md" })
  local head = git({ "rev-parse", "HEAD" })
  local _, refused, refused_err = git(vim.list_extend(vim.deepcopy(commit), { "-m", "stale" }))
  ok(refused ~= 0, "a commit with a stale staged index is refused")
  ok(refused_err:find("tasks index lib.nvim --staged", 1, true), "naming the fix: " .. refused_err)
  eq(git({ "rev-parse", "HEAD" }), head, "and no commit was made")

  ok(index.stage_area("lib.nvim", { root = root }), "stage the index")
  local _, passed, passed_err = git(vim.list_extend(vim.deepcopy(commit), { "-m", "four" }))
  eq(passed, 0, "with the index staged the commit goes through: " .. passed_err)

  -- `git commit -- <paths>` commits the tree's version of the paths from a staging area of its own: the hook checks
  -- that one. Here the tree's TASKS.md is the old one (the trap of `index --staged` followed by a commit with paths).
  git({ "checkout", "--", "lib.nvim/ROADMAP/TASKS.md" })
  F.task(H, root, "lib.nvim", "five", F.meta("Five", "open"))
  git({ "add", "--", "lib.nvim/ROADMAP/tasks/five.md" })
  ok(index.stage_area("lib.nvim", { root = root }), "the shared staging area is right")
  head = git({ "rev-parse", "HEAD" })
  local _, by_path, by_path_err = git(
    vim.list_extend(
      vim.deepcopy(commit),
      { "-m", "five", "--", "lib.nvim/ROADMAP/tasks/five.md", "lib.nvim/ROADMAP/TASKS.md" }
    )
  )
  ok(
    by_path ~= 0,
    "a commit with paths that takes the tree's stale index is refused: " .. by_path_err
  )
  eq(git({ "rev-parse", "HEAD" }), head, "and no commit was made")

  -- The same commit with paths, the tree's index brought in line first: it goes through.
  ok(index.write_area("lib.nvim", { root = root }), "the tree's index is rewritten")
  local _, by_path_ok, by_path_ok_err = git(
    vim.list_extend(
      vim.deepcopy(commit),
      { "-m", "five", "--", "lib.nvim/ROADMAP/tasks/five.md", "lib.nvim/ROADMAP/TASKS.md" }
    )
  )
  eq(by_path_ok, 0, "a commit with paths and a matching index passes: " .. by_path_ok_err)

  -- A tasks.nvim from before the check (found first, e.g. a shared checkout not pulled yet) ends with a usage error:
  -- that is no verdict, so the commit goes through with a note instead of every commit of the vault being refused.
  local old = H.tmpdir() .. "/old-tasks.nvim"
  H.write(old .. "/scripts/tasks.lua", 'io.stderr:write("error: unknown option\\n") os.exit(2)\n')
  F.task(H, root, "lib.nvim", "six", F.meta("Six", "open"))
  git({ "add", "--", "lib.nvim/ROADMAP/tasks/six.md" })
  local with_old = vim
    .system(
      vim.list_extend({ "git", "-C", root }, vim.list_extend(vim.deepcopy(commit), { "-m", "six" })),
      { text = true, env = { TASKS_NVIM_DIR = old } }
    )
    :wait()
  eq(
    with_old.code,
    0,
    "an engine without the check lets the commit pass: " .. tostring(with_old.stderr)
  )
  ok(
    tostring(with_old.stderr):find("does not know index --staged --check", 1, true),
    "and says why: " .. tostring(with_old.stderr)
  )
end
