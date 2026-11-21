-- TESTS/tasks_index_staged_check_spec.lua -- `index [<area>] --staged --check`: whether the staged
-- ROADMAP/TASKS.md is the one the staged tasks render to. It writes nothing and reads only the areas with a staged
-- change. The hook that runs it at `git commit`: TESTS/tasks_vault_hook_spec.lua.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local index = require("tasks_nvim.index")
  local cli = require("tasks_nvim.cli")

  local root = F.vault(H)

  ---@param args string[]
  ---@param env? table<string, string>
  ---@return string stdout
  ---@return integer code
  ---@return string stderr
  local function git(args, env)
    local res =
      vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true, env = env }):wait()
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
  local _, seed = git(vim.list_extend(vim.deepcopy(ID), { "commit", "-q", "-m", "seed" }))
  eq(seed, 0, "seed commit")

  -- Nothing staged: no area to check.
  local code, said = run({ "index", "--staged", "--check" })
  eq(code, 0, "an empty staging area passes: " .. said)
  ok(said:find("0 area", 1, true), "and checks no area: " .. said)

  -- Passing: a new task staged together with the index built from the staging area.
  F.task(H, root, "lib.nvim", "two", F.meta("Two", "open"))
  git({ "add", "--", "lib.nvim/ROADMAP/tasks/two.md" })
  ok(index.stage_area("lib.nvim", { root = root }), "stage the index")
  code, said = run({ "index", "lib.nvim", "--staged", "--check" })
  eq(code, 0, "the staged index matches the staged tasks: " .. said)
  code, said = run({ "index", "--staged", "--check" })
  eq(code, 0, "and so for every staged area: " .. said)
  ok(said:find("1 area", 1, true), "lib.nvim is the one area checked: " .. said)

  -- Stale: a third task staged, the index left as it was. Nothing is written or staged by the check.
  F.task(H, root, "lib.nvim", "three", F.meta("Three", "open"))
  git({ "add", "--", "lib.nvim/ROADMAP/tasks/three.md" })
  local before = git({ "ls-files", "-s" })
  local tree_index = table.concat(vim.fn.readfile(root .. "/lib.nvim/ROADMAP/TASKS.md"), "\n")
  code, said = run({ "index", "--staged", "--check" })
  eq(code, 1, "a stale staged index fails: " .. said)
  ok(
    said:find("stale\tlib.nvim\t3 open\tlib.nvim/ROADMAP/TASKS.md (outdated)", 1, true),
    "with a `stale` line: " .. said
  )
  ok(said:find("tasks index lib.nvim --staged", 1, true), "and the command to fix it: " .. said)
  eq(git({ "ls-files", "-s" }), before, "the check stages nothing")
  eq(
    table.concat(vim.fn.readfile(root .. "/lib.nvim/ROADMAP/TASKS.md"), "\n"),
    tree_index,
    "and writes nothing"
  )
  local res = index.stage_area("lib.nvim", { root = root, check = true })
  eq(res.action, "stale", "stage_area with check: stale")
  eq(res.reason, "outdated", "because the staged index differs")
  ok(index.stage_area("lib.nvim", { root = root }), "fixed")
  eq(run({ "index", "--staged", "--check" }), 0, "and the check passes again")
  git(vim.list_extend(vim.deepcopy(ID), { "commit", "-q", "-m", "three" }))

  -- `done` moves a task out of ROADMAP/tasks/: a rename the check must see as the area's change.
  vim.fn.mkdir(root .. "/lib.nvim/Backlog/TASKS", "p")
  git({ "mv", "lib.nvim/ROADMAP/tasks/three.md", "lib.nvim/Backlog/TASKS/2026-10-03_three.md" })
  eq(index.staged_areas({ root = root }), { "lib.nvim" }, "a task that left names its area")
  code, said = run({ "index", "--staged", "--check" })
  eq(code, 1, "the moved task leaves the index stale: " .. said)

  -- An area without open tasks: the staged index must go (orphan), and once gone the check passes.
  git({
    "rm",
    "-q",
    "--cached",
    "--",
    "lib.nvim/ROADMAP/tasks/one.md",
    "lib.nvim/ROADMAP/tasks/two.md",
  })
  res = index.stage_area("lib.nvim", { root = root, check = true })
  eq(res and res.action, "stale", "an index without open tasks is stale")
  eq(res.reason, "orphan", "as an orphan")
  eq(res.open, 0, "with no open task")
  ok(index.stage_area("lib.nvim", { root = root }), "the index leaves the staging area")
  code, said = run({ "index", "lib.nvim", "--staged", "--check" })
  eq(code, 0, "an area without open tasks and without index passes: " .. said)
  git({ "reset", "-q" })

  -- An area that is none is an error, not a pass.
  code, said = run({ "index", "no-such.nvim", "--staged", "--check" })
  eq(code, 1, "an unknown area fails: " .. said)
  ok(said:find("unknown area", 1, true), "and says so: " .. said)

  -- Usage.
  eq(run({ "index", "--staged", "--check", "--all" }), 2, "--all is no option of the check")
  eq(run({ "index", "--staged" }), 2, "--staged without --check still takes an area")
end
