-- TESTS/tasks_tree_spec.lua -- the vault in a tree view (`tasks_nvim.integrations.tree`): the entries at
-- lib.nvim.tree.registry (a decorator with the count of open tasks, the view `tasks`, the actions done and claim) and
-- the counts behind them (`tree_counts`: read from the index heads, kept current by the write hook and a watcher).
-- That a tree draws a registered badge and offers a registered action is filetree.nvim's own spec.
-- @scans-data: it lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local registry = require("lib.nvim.tree.registry")
  local index = require("tasks_nvim.index")
  local vault = require("tasks_nvim.vault")
  local counts = require("tasks_nvim.integrations.tree_counts")
  local tree = require("tasks_nvim.integrations.tree")

  -- ── the count in the head of an index ──────────────────────────────────────
  local head = index.GENERATED_MARK .. "\n# lib.nvim — offene Tasks (12)\n\n| Status |\n"
  eq(counts.parse_count(head), 12)
  eq(counts.parse_count(H.crlf(head)), 12, "a CRLF checkout")
  eq(
    counts.parse_count("# lib.nvim — offene Tasks (12)\n"),
    nil,
    "no marker: somebody's own file"
  )
  eq(counts.parse_count(index.GENERATED_MARK .. "\n# no count here\n"), nil)
  eq(
    counts.parse_count(index.GENERATED_MARK .. "\n# a (b) — offene Tasks (3)\n"),
    3,
    "the last bracket"
  )
  eq(counts.norm("c:\\vault\\area\\"), "C:/vault/area", "the spelling a tree uses for its keys")
  eq(counts.norm("/vault/area/"), "/vault/area")

  -- ── fixture: two areas with open tasks ─────────────────────────────────────
  local root = F.vault(H)
  vault.set_root(root)
  F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "open", { { "prio", "2" } }))
  F.task(H, root, "lib.nvim", "beta", F.meta("Beta", "doing", { { "prio", "3" } }))
  F.task(H, root, "cascade.nvim", "gamma", F.meta("Gamma", "open"))
  local written, write_errors = index.write_all({ root = root })
  eq(write_errors, {})
  ok(#written > 0)
  local key = counts.norm(root)

  -- the watcher is a seam: what is watched and what an event does is checked without the file system's timing
  local watched, stopped = {}, 0
  counts.start_watch = function(path, on_change)
    watched[#watched + 1] = { path = path, fire = on_change }
    return {
      stop = function()
        stopped = stopped + 1
      end,
    }
  end

  -- ── registering ────────────────────────────────────────────────────────────
  ok(tree.register(), "registered")

  -- the view shown before any badge was asked for: it reads the heads itself, and a listener that is
  -- already there hears nothing from inside that answer
  do
    local view = registry.get("source", tree.SOURCE)
    local heard = 0
    local stop = view.subscribe({}, {
      reset = function()
        heard = heard + 1
      end,
    })
    local got
    local node = view.root({})
    node.children(node, function(list)
      got = list
    end)
    eq(#got, 2, "both areas, read on the spot")
    eq(heard, 0, "no reset from inside the answer")
    ok(
      vim.wait(1000, function()
        return heard > 0
      end, 5),
      "the read of the first listener still reports"
    )
    stop()
    vault.set_root(nil)
    vault.configure({})
    counts.refresh(true)
    eq(counts.areas(), {}, "fixture: the table is empty again")
    vault.set_root(root)
    require("tasks_nvim.vault").configure({
      extra_areas = { "ALL", "nvim-config", "docmap-desktop", "migrate.nvim" },
    })
    watched, stopped = {}, 0
  end
  local decorator = registry.get("decorator", tree.DECORATOR)
  local source = registry.get("source", tree.SOURCE)
  local done = registry.get("action", tree.ACTION_DONE)
  local claim = registry.get("action", tree.ACTION_CLAIM)
  ok(decorator and source and done and claim, "four entries")
  eq(decorator.key, "path")
  eq(done.key, nil, "without a configured key the actions have none")
  ok(done.mutates and claim.mutates, "both say that they change files")
  ok(done.desc ~= "" and claim.desc ~= "")

  -- ── the decorator ──────────────────────────────────────────────────────────
  eq(decorator.get(key .. "/lib.nvim"), nil, "nothing is read before a tree listens")
  eq(counts.watched(), 0)
  local emitted = {}
  local unsubscribe = decorator.subscribe(function(keys)
    emitted[#emitted + 1] = keys or "all"
  end)
  eq(emitted, {}, "subscribing reads nothing itself: a tree subscribes while it opens")
  ok(
    vim.wait(1000, function()
      return #emitted > 0
    end, 5),
    "the first read comes a moment later"
  )
  eq(emitted, { "all" }, "... and tells the tree to look at everything")
  eq(decorator.get(key .. "/lib.nvim").text, "2")
  eq(decorator.get(key .. "/lib.nvim").count, 2)
  eq(decorator.get(key .. "/lib.nvim/ROADMAP").text, "2", "rolled up through ROADMAP")
  eq(decorator.get(key .. "/lib.nvim/ROADMAP/tasks").text, "2")
  eq(decorator.get(key .. "/cascade.nvim").text, "1")
  eq(decorator.get(key .. "/ALL"), nil, "an area without open tasks has no badge")
  eq(decorator.get(key .. "/lib.nvim/ROADMAP/tasks/alpha.md"), nil, "a task file has none")
  eq(vim.tbl_count(decorator.all()), 6, "three paths per area")

  local dirs = vim.tbl_map(function(w)
    return w.path
  end, watched)
  table.sort(dirs)
  eq(
    dirs,
    { root .. "/cascade.nvim/ROADMAP", root .. "/lib.nvim/ROADMAP" },
    "watched: ROADMAP of each area that has one (and _Telemetry, TEMPLATES are no areas)"
  )
  eq(counts.watched(), 2)

  -- this Neovim writes an index: the hook, no watcher needed
  emitted = {}
  F.task(H, root, "lib.nvim", "delta", F.meta("Delta", "open"))
  eq(assert(index.write_area("lib.nvim", { root = root })).action, "written")
  eq(decorator.get(key .. "/lib.nvim").text, "3")
  eq(#emitted, 1)
  eq(emitted[1], counts.badge_paths(root, "lib.nvim"), "exactly the keys of that area")

  -- the same count, other rows: nothing to redraw for the badge
  emitted = {}
  F.task(H, root, "lib.nvim", "delta", F.meta("Delta renamed", "doing"))
  eq(assert(index.write_area("lib.nvim", { root = root })).action, "written")
  eq(emitted, {}, "the count is the same")

  -- a check run and an index of another vault change nothing
  local other = H.tmpdir() .. "/other"
  F.task(H, other, "lib.nvim", "x", F.meta("X", "open"))
  vim.fn.mkdir(other .. "/lib.nvim/Backlog", "p")
  eq(assert(index.write_area("lib.nvim", { root = other })).action, "written")
  eq(decorator.get(key .. "/lib.nvim").text, "3", "another vault's index is not ours")
  eq(emitted, {})

  -- the last open task goes: the index is removed, the badge with it
  vim.fn.delete(root .. "/cascade.nvim/ROADMAP/tasks/gamma.md")
  eq(assert(index.write_area("cascade.nvim", { root = root })).action, "removed")
  eq(decorator.get(key .. "/cascade.nvim"), nil)
  eq(#emitted, 1)

  -- somebody else writes an index (the CLI, another Neovim): the watcher
  emitted = {}
  H.write(
    root .. "/cascade.nvim/ROADMAP/TASKS.md",
    index.GENERATED_MARK .. "\n# cascade.nvim — offene Tasks (7)\n"
  )
  eq(decorator.get(key .. "/cascade.nvim"), nil, "not read while drawing")
  for _, w in ipairs(watched) do
    if w.path == root .. "/cascade.nvim/ROADMAP" then
      w.fire()
    end
  end
  ok(
    vim.wait(1000, function()
      return decorator.get(key .. "/cascade.nvim") ~= nil
    end, 10),
    "an event reads the head of that area again"
  )
  eq(decorator.get(key .. "/cascade.nvim").text, "7")
  eq(#emitted, 1)

  -- ── the view ───────────────────────────────────────────────────────────────
  eq({ source.available() }, { true })
  local resets = 0
  local unsubscribe_source = source.subscribe({}, {
    reset = function()
      resets = resets + 1
    end,
  })
  local function children_of(node)
    local got, err
    node.children(node, function(list, e)
      got, err = list, e
    end)
    return got, err
  end
  local root_node = source.root({})
  eq(root_node.id, "tasks:root")
  local areas = children_of(root_node)
  eq(
    vim.tbl_map(function(n)
      return { n.id, n.label, n.kind, n.path }
    end, areas),
    {
      { "tasks:cascade.nvim", "cascade.nvim", "group", root .. "/cascade.nvim" },
      { "tasks:lib.nvim", "lib.nvim", "group", root .. "/lib.nvim" },
    },
    "the areas with open tasks, each with its folder (where the badge of the count is drawn)"
  )
  local tasks = children_of(areas[2])
  eq(
    vim.tbl_map(function(n)
      return { n.id, n.label, n.kind, n.columns[1] }
    end, tasks),
    {
      { "tasks:lib.nvim/beta", "Beta", "task", "doing" },
      { "tasks:lib.nvim/delta", "Delta renamed", "task", "doing" },
      { "tasks:lib.nvim/alpha", "Alpha", "task", "open" },
    },
    "the open tasks in the order of the index"
  )
  eq(tasks[3].path, root .. "/lib.nvim/ROADMAP/tasks/alpha.md", "a task node is its file")
  eq(tasks[3].data.task_id, "lib.nvim/alpha")

  -- a change of the index asks the view again
  F.task(H, root, "lib.nvim", "alpha", F.meta("Alpha", "doing", { { "prio", "2" } }))
  eq(assert(index.write_area("lib.nvim", { root = root })).action, "written")
  eq(resets, 1, "the same count, another status: the view still reads again")

  -- ── which nodes are tasks ──────────────────────────────────────────────────
  eq(tree.task_id(tasks[3]), "lib.nvim/alpha", "a node of the view")
  eq(tree.task_id({ path = root .. "/lib.nvim/ROADMAP/tasks/alpha.md" }), "lib.nvim/alpha")
  eq(
    tree.task_id({ path = root:gsub("/", "\\") .. "\\lib.nvim\\ROADMAP\\tasks\\alpha.md" }),
    "lib.nvim/alpha",
    "either slash"
  )
  eq(
    tree.task_id({ path = root .. "/lib.nvim/ROADMAP/tasks/big/big.md" }),
    "lib.nvim/big",
    "a folder task"
  )
  eq(
    tree.task_id({ path = root .. "/lib.nvim/ROADMAP/tasks/big/notes.md" }),
    nil,
    "a file next to it"
  )
  eq(tree.task_id({ path = root .. "/lib.nvim/ROADMAP/TASKS.md" }), nil, "the index")
  eq(tree.task_id({ path = root .. "/lib.nvim/ROADMAP/tasks" }), nil, "a folder")
  eq(tree.task_id({ path = root .. "/lib.nvim/ROADMAP/tasks/alpha.txt" }), nil)
  eq(tree.task_id({ path = other .. "/lib.nvim/ROADMAP/tasks/x.md" }), nil, "another vault")
  eq(tree.task_id({ id = "x" }), nil, "a node without a path")
  eq(tree.task_id(nil), nil)
  ok(done.when(tasks[3], {}) and claim.when(tasks[3], {}))
  ok(not done.when({ path = root .. "/lib.nvim/ROADMAP/TASKS.md" }, {}))

  -- ── what the actions run ───────────────────────────────────────────────────
  local ran, notes = {}, {}
  local real_cmd, real_notify = package.loaded["tasks_nvim.ui.cmd"], vim.notify
  package.loaded["tasks_nvim.ui.cmd"] = {
    task_done = function(ctx)
      ran[#ran + 1] = { "done", ctx }
    end,
    task_claim = function(ctx)
      ran[#ran + 1] = { "claim", ctx }
    end,
  }
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg, level }
  end
  done.run({ tasks[3] }, {})
  eq(
    ran,
    { { "done", { args = { id = "lib.nvim/alpha" }, kv = {}, flags = {}, rest = {} } } },
    "what `:Tasks done lib.nvim/alpha` hands its handler: no --yes, so it asks"
  )
  eq(notes, {})

  ran = {}
  done.run({ tasks[1], tasks[3], tasks[1] }, {})
  eq(#ran, 1, "finishing asks a question per task: one at a time")
  eq(ran[1][2].args.id, "lib.nvim/beta")
  eq(#notes, 1)
  has(notes[1][1], "2 tasks are marked; finishing the first only: lib.nvim/beta")
  eq(notes[1][2], vim.log.levels.WARN)

  ran, notes = {}, {}
  claim.run({ tasks[1], { path = root .. "/README.md" }, tasks[3] }, {})
  eq(
    vim.tbl_map(function(r)
      return r[1] .. " " .. r[2].args.id
    end, ran),
    { "claim lib.nvim/beta", "claim lib.nvim/alpha" },
    "every marked task is claimed, what is no task is left out"
  )
  done.run({ { path = root .. "/README.md" } }, {})
  eq(#ran, 2, "no task under the cursor: nothing runs")
  eq(notes, {})
  package.loaded["tasks_nvim.ui.cmd"], vim.notify = real_cmd, real_notify

  -- ── nobody listens any more ────────────────────────────────────────────────
  unsubscribe_source()
  eq(stopped, 0, "the decorator still listens")
  unsubscribe()
  eq(stopped, 2, "the last listener closes every handle")
  eq(counts.watched(), 0)
  F.task(H, root, "lib.nvim", "epsilon", F.meta("Epsilon", "open"))
  eq(assert(index.write_area("lib.nvim", { root = root })).action, "written")
  eq(decorator.get(key .. "/lib.nvim").text, "3", "and nothing is read for nobody")

  -- ── without a vault ────────────────────────────────────────────────────────
  local env_vault = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = nil
  vault.set_root(nil)
  vault.configure({})
  local available, reason = source.available()
  eq(available, false)
  has(reason, "vault not found")
  eq(children_of(source.root({})), {}, "an empty view, not an error")
  emitted = {}
  local unsubscribe_empty = decorator.subscribe(function(keys)
    emitted[#emitted + 1] = keys or "all"
  end)
  vim.wait(1000, function()
    return #emitted > 0
  end, 5)
  eq(emitted, { "all" }, "the badges of the vault that is gone are taken back")
  eq(decorator.all(), {})
  eq(counts.watched(), 0)
  unsubscribe_empty()
  vim.env.TASKS_VAULT = env_vault

  -- ── unregister, and the option of setup ────────────────────────────────────
  tree.unregister()
  eq(registry.get("decorator", tree.DECORATOR), nil)
  eq(registry.get("source", tree.SOURCE), nil)
  eq(registry.get("action", tree.ACTION_DONE), nil)
  eq(registry.get("action", tree.ACTION_CLAIM), nil)

  local config = require("tasks_nvim.config")
  eq(config.validate({ tree = false }).tree, false)
  eq(config.validate({ tree = true }).tree, true)
  eq(
    config.validate({ tree = { keys = { done = "gd", claim = { "gc", "gC" } } } }).tree,
    { keys = { done = "gd", claim = { "gc", "gC" } } }
  )
  eq(config.validate({ tree = { keys = { done = false } } }).tree, { keys = { done = false } })
  eq(config.validate({ tree = {} }).tree, { keys = {} })
  eq(config.validate({ tree = "yes" }).tree, nil, "not a table: the default stays")
  eq(config.validate({ tree = { key = "gd" } }).tree, nil, "an unknown key is refused")
  eq(config.validate({ tree = { keys = { finish = "gd" } } }).tree, nil, "an unknown action")
  eq(config.validate({ tree = { keys = { done = 3 } } }).tree, nil)
  config.take_unannounced()

  local tasks_nvim = require("tasks_nvim")
  local quiet = { reminders = { on_start = false } }
  tasks_nvim.setup(quiet)
  ok(registry.get("decorator", tree.DECORATOR), "setup registers by default")
  eq(registry.get("action", tree.ACTION_DONE).key, nil)
  tasks_nvim.setup(
    vim.tbl_extend("force", quiet, { tree = { keys = { done = "gd", claim = false } } })
  )
  eq(registry.get("action", tree.ACTION_DONE).key, "gd", "a configured key")
  eq(registry.get("action", tree.ACTION_CLAIM).key, nil, "false: no key")
  tasks_nvim.setup(vim.tbl_extend("force", quiet, { tree = false }))
  eq(registry.get("decorator", tree.DECORATOR), nil, "tree = false takes the entries out again")
  eq(registry.get("source", tree.SOURCE), nil)
  eq(registry.get("action", tree.ACTION_DONE), nil)
  -- let what setup scheduled run before the spec ends
  vim.wait(50, function()
    return false
  end)
  counts.start_watch = nil
end
