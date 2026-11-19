-- TESTS/tasks_meeting_links_spec.lua -- how a meeting follows the tasks it names: `move_area` rewrites its `tasks:` and
-- the arrow of a follow-up (and refuses a slug a meeting has in the target area), `done` of a follow-up task ticks its
-- line in the meeting, and `find` names the meetings of a task (kind `meeting`) beside the tasks (kind `task`).
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local meetings = require("tasks_nvim.meetings")
  local mutate = require("tasks_nvim.mutate")
  local ops_mod = require("tasks_nvim.ops")
  local find = require("tasks_nvim.find")

  local root = F.vault(H)
  meetings.reset_cache()
  F.task(H, root, "lib.nvim", "prep", F.meta("Prep", "open"))
  F.task(H, root, "lib.nvim", "other", F.meta("Other", "open"))
  require("tasks_nvim.index").write_area("lib.nvim", { root = root })

  local function one(op, dry)
    local doc, err = ops_mod.run(
      { ops = { op }, dry_run = dry or nil },
      { root = root, today = F.TODAY }
    )
    assert(doc, tostring(err))
    return doc.results[1]
  end
  local function file(id)
    meetings.reset_cache()
    return assert(meetings.find(id, { root = root }))
  end

  local id = one({
    op = "meeting_new",
    area = "lib.nvim",
    title = "Sync",
    fields = { date = "2026-10-20", tasks = { "lib.nvim/prep", "lib.nvim/other" } },
  }).id
  eq(
    one({
      op = "meeting_capture",
      id = id,
      entry = { kind = "task", text = "Lizenz", at = "10:00" },
    }).ok,
    true
  )
  local fu = one({ op = "meeting_followups", id = id })
  eq(fu.items[1].id, "lib.nvim/lizenz")

  -- ── find: the tasks that name the meeting, and the meetings that name a task ──
  local by_meeting = find.by_refs({ id }, { root = root })
  eq(#by_meeting, 1)
  eq(by_meeting[1].id, "lib.nvim/lizenz")
  eq(by_meeting[1].kind, "task")
  local by_task = find.by_refs({ "lib.nvim/prep", "lib.nvim/lizenz" }, { root = root })
  eq(#by_task, 2, vim.inspect(by_task))
  for _, m in ipairs(by_task) do
    eq(m.kind, "meeting")
    eq(m.id, id)
    eq(m.location, "open")
  end
  eq(#find.by_refs({ "lib.nvim/prep" }, { root = root, tasks_only = true }), 0)
  -- through the contract: the match carries its kind
  local doc =
    assert(require("tasks_nvim.contract").find({ refs = { "lib.nvim/prep" } }, { root = root }))
  eq(doc.matches[1].kind, "meeting")

  -- ── move_area: tasks: and the arrow name the new id ──
  local preview = one({ op = "move_area", id = "lib.nvim/prep", to_area = "cascade.nvim" }, true)
  local kinds = {}
  for _, r in ipairs(preview.move.references) do
    kinds[#kinds + 1] = r.kind .. ":" .. r.id
  end
  ok(vim.tbl_contains(kinds, "meeting:" .. id), vim.inspect(kinds))
  local moved = one({ op = "move_area", id = "lib.nvim/prep", to_area = "cascade.nvim" })
  eq(moved.ok, true, vim.inspect(moved))
  eq(file(id).tasks, { "cascade.nvim/prep", "lib.nvim/other" })
  local moved2 = one({ op = "move_area", id = "lib.nvim/lizenz", to_area = "cascade.nvim" })
  eq(moved2.ok, true, vim.inspect(moved2))
  eq(file(id).followups[1].task, "cascade.nvim/lizenz")
  local rewritten = {}
  for _, r in ipairs(moved2.rewritten or {}) do
    rewritten[#rewritten + 1] = r.kind
  end
  ok(vim.tbl_contains(rewritten, "meeting"), vim.inspect(moved2))
  -- a slug a meeting has in the target area is taken
  F.task(H, root, "cascade.nvim", "sync-2026-10-20", F.meta("Clash", "open"))
  local clash =
    one({ op = "move_area", id = "cascade.nvim/sync-2026-10-20", to_area = "lib.nvim" }, true)
  local conflict_codes = {}
  for _, c in ipairs(clash.move and clash.move.conflicts or {}) do
    conflict_codes[#conflict_codes + 1] = c.code
  end
  ok(vim.tbl_contains(conflict_codes, "slug-taken"), vim.inspect(clash))

  -- ── done of the follow-up task ticks its line ──
  eq(file(id).followups[1].ticked, false)
  local preview_done = one({ op = "done", id = "cascade.nvim/lizenz" }, true)
  local token = mutate.confirm_token("cascade.nvim/lizenz", preview_done.etag_before)
  local done = one({ op = "done", id = "cascade.nvim/lizenz", confirm = token })
  eq(done.outcome, "done", vim.inspect(done))
  eq(file(id).followups[1].ticked, true)
  -- a meeting the follow-up does not name is left alone
  eq(file(id).agenda, {})
end
