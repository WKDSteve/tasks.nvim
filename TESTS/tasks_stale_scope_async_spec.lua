-- TESTS/tasks_stale_scope_async_spec.lua -- `:Tasks plan|estimate|quickwins --stale=refs` never make the editor wait
-- for git: the command returns before git answered (the synchronous dater must not run), the answer delivers once,
-- and a newer command of the same name cancels the delivery of the older one.

---@diagnostic disable: duplicate-set-field
-- Why: the spec replaces module functions with test doubles on purpose, so no git is started.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local staleness = require("tasks_nvim.staleness")
  local view = require("tasks_nvim.ui.view")
  local cmd = require("tasks_nvim.ui.cmd")

  local root = F.vault(H)
  local repos = H.tmpdir()
  H.write(repos .. "/lib.nvim/README.md", "# lib\n")
  F.task(
    H,
    root,
    "lib.nvim",
    "docs-drifted",
    F.meta("Docs drifted", "open", { { "updated", "2026-01-01" }, { "refs", "[README.md]" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "no-refs-at-all",
    F.meta("No refs at all", "open", { { "updated", "2026-01-01" } })
  )
  require("tasks_nvim").setup({ vault = root, staleness = { repo_bases = { repos } } })

  local real = {
    git_dates = staleness.git_dates,
    git_dates_async = staleness.git_dates_async,
    deliver_text = view.deliver_text,
  }
  local sync_calls = 0
  ---@type { base: string, rels: string[], cb: fun(dates: table|nil, err: string|nil) }[]
  local asked = {}
  local delivered = {} ---@type string[]
  staleness.git_dates = function()
    sync_calls = sync_calls + 1
    error("the editor waited for git")
  end
  staleness.git_dates_async = function(base, rels, _, cb)
    asked[#asked + 1] = { base = base, rels = rels, cb = cb }
  end
  view.deliver_text = function(text)
    delivered[#delivered + 1] = text
    return true
  end

  ---git's answer: every file asked for changed after the task's `updated`.
  ---@param q { rels: string[], cb: fun(dates: table|nil, err: string|nil) }
  local function answer(q)
    local out = {}
    for _, rel in ipairs(q.rels) do
      out[rel] = { date = "2030-01-01", file = rel }
    end
    q.cb(out, nil)
  end

  ---@param flags? table
  local function plan_ctx(flags)
    return {
      args = { area = "lib.nvim" },
      flags = vim.tbl_extend("force", { stale = "refs", format = "ids" }, flags or {}),
      rest = {},
    }
  end

  local run_ok, err = pcall(function()
    -- plan: the command returns at once, the delivery waits for git's answer
    cmd.plan(plan_ctx())
    eq(sync_calls, 0, "plan never dates the refs synchronously")
    eq(#delivered, 0, "nothing is delivered before git answered")
    eq(cmd.pending_ref_checks(), 1, "one background check runs")
    ok(
      vim.wait(2000, function()
        return #asked == 1
      end, 5),
      "git is asked in the background"
    )
    has(asked[1].base, "lib.nvim", "the repo of the area")
    answer(asked[1])
    ok(
      vim.wait(2000, function()
        return #delivered == 1
      end, 5),
      "the plan is delivered once git answered"
    )
    has(delivered[1], "lib.nvim/docs-drifted", "the task whose ref changed")
    lacks(delivered[1], "lib.nvim/no-refs-at-all", "a task without refs is no stale task")
    eq(cmd.pending_ref_checks(), 0, "no check left")

    -- a newer plan cancels the older one: its late answer delivers nothing
    asked, delivered = {}, {}
    cmd.plan(plan_ctx())
    ok(vim.wait(2000, function()
      return #asked == 1
    end, 5))
    cmd.plan(plan_ctx())
    eq(cmd.pending_ref_checks(), 1, "the older check is no longer counted")
    vim.wait(50, function()
      return false
    end)
    ok(#asked >= 1, "the newer plan asks git")
    answer(asked[1])
    if asked[2] then
      answer(asked[2])
    end
    vim.wait(200, function()
      return false
    end)
    eq(#delivered, 1, "only the newer plan is delivered")
    eq(cmd.pending_ref_checks(), 0)

    -- estimate and quickwins take the same way
    for _, name in ipairs({ "estimate", "quickwins" }) do
      asked = {}
      cmd[name](plan_ctx({ format = name == "quickwins" and "ids" or nil }))
      eq(sync_calls, 0, name .. " never dates the refs synchronously")
      eq(cmd.pending_ref_checks(), 1, name .. ": one background check")
      ok(vim.wait(2000, function()
        return #asked == 1
      end, 5))
      answer(asked[1])
      ok(
        vim.wait(2000, function()
          return cmd.pending_ref_checks() == 0
        end, 5),
        name .. " answered"
      )
    end

    -- without --stale=refs nothing changes: the plan is delivered before the command returns
    delivered = {}
    cmd.plan({ args = { area = "lib.nvim" }, flags = { format = "ids" }, rest = {} })
    eq(#delivered, 1, "a plan without --stale=refs is delivered at once")
  end)
  staleness.git_dates = real.git_dates
  staleness.git_dates_async = real.git_dates_async
  view.deliver_text = real.deliver_text
  assert(run_ok, err)
end
