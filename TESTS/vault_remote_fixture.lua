-- TESTS/vault_remote_fixture.lua -- a vault with a bare repository as its remote and a second clone ("another
-- session"), for the specs of `tasks push` and of the merge driver.

local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
local index = require("tasks_nvim.index")
local cli = require("tasks_nvim.cli")

return function(H)
  local eq, ok = H.eq, H.ok
  local R = { F = F }

  ---@param dir string
  ---@param args string[]
  ---@return string stdout
  ---@return integer code
  function R.git(dir, args)
    local res = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
    return vim.trim(res.stdout or ""), res.code
  end
  ---@param dir string
  function R.configure(dir)
    R.git(dir, { "config", "core.autocrlf", "false" })
    R.git(dir, { "config", "user.name", "t" })
    R.git(dir, { "config", "user.email", "t@example.org" })
    R.git(dir, { "config", "commit.gpgsign", "false" })
  end
  ---Add a task to `area`, render the index, commit both.
  ---@param root string
  ---@param area string
  ---@param slug string
  ---@return string sha
  function R.add_task(root, area, slug)
    F.task(H, root, area, slug, F.meta(slug, "open"))
    ok(index.write_area(area, { root = root }), "index of " .. area)
    R.git(root, { "add", "--", area })
    eq(select(2, R.git(root, { "commit", "-q", "-m", "add " .. slug })), 0, "commit " .. slug)
    return (R.git(root, { "rev-parse", "HEAD" }))
  end

  function R.setup_remote()
    local root = F.vault(H)
    local bare = H.tmpdir() .. "/remote.git"
    eq(select(2, R.git(root, { "init", "-q", "-b", "main" })), 0, "git init")
    R.configure(root)
    F.task(H, root, "lib.nvim", "keep", F.meta("Keep", "open"))
    F.task(H, root, "cascade.nvim", "other", F.meta("Other", "open"))
    ok(index.write_all({ root = root }), "seed indexes")
    R.git(root, { "add", "." })
    R.git(root, { "commit", "-q", "-m", "seed" })
    eq(
      select(2, R.git(H.tmpdir(), { "init", "-q", "--bare", "-b", "main", bare })),
      0,
      "bare remote"
    )
    R.git(root, { "remote", "add", "origin", bare })
    eq(select(2, R.git(root, { "push", "-q", "origin", "main" })), 0, "seed push")
    R.git(root, { "branch", "--set-upstream-to=origin/main" })
    local other = H.tmpdir() .. "/other"
    eq(select(2, R.git(H.tmpdir(), { "clone", "-q", bare, other })), 0, "second session")
    R.configure(other)
    require("tasks_nvim.vault").configure({
      extra_areas = { "ALL", "nvim-config", "docmap-desktop", "migrate.nvim" },
    })
    return root, other, bare
  end

  ---@param root string
  ---@param args string[]
  ---@return integer code
  ---@return string said
  function R.run(root, args)
    local said = {}
    local function put(s)
      said[#said + 1] = s
    end
    local code =
      cli.run(vim.list_extend(vim.deepcopy(args), { "--vault=" .. root }), { out = put, err = put })
    return code, table.concat(said, "\n")
  end

  ---Every area of a clone of `bare` renders to the committed index.
  function R.remote_indexes_fresh(bare, label)
    local check = H.tmpdir() .. "/check-" .. label
    eq(select(2, R.git(H.tmpdir(), { "clone", "-q", bare, check })), 0, "clone for " .. label)
    for _, r in ipairs(index.write_all({ root = check, check = true })) do
      eq(r.action, "unchanged", label .. ": index of " .. r.area)
    end
    return check
  end

  return R
end
