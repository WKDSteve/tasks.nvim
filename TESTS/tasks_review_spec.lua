-- TESTS/tasks_review_spec.lua -- the review of a finished task (`:Tasks agent <id> kind=review-done`): the block of
-- ai-desktop's answer, the section it becomes after a yes, the follow-up task after a second yes, watching the job, and
-- the hint of the done flow. ai-desktop is a stand-in throughout.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local review = require("tasks_nvim.review")
  local agent = require("tasks_nvim.agent")

  local BLOCK = table.concat({
    "## Prüfung",
    "",
    "2026-11-18, review job 0123456789abcdef: one open",
    "",
    "- [x] it is done — erfüllt: feature.txt:1",
    "- [ ] it is documented — offen: no README change",
    "",
    "### Folgetask (Vorschlag)",
    "",
    "- title: Document it",
    "- summary: The README names it.",
  }, "\n")
  local OUTPUT = "▸ Claude Code\nChecked it.\n\n<!-- review:begin -->\n"
    .. BLOCK
    .. "\n<!-- review:end -->\n"

  -- ── the block ──────────────────────────────────────────────────────────────
  eq(review.block(OUTPUT), BLOCK)
  eq(
    review.block("<!-- review:begin -->\nold\n<!-- review:end -->\n" .. OUTPUT),
    BLOCK,
    "the last block counts"
  )
  eq(review.block("no block"), nil)
  eq(review.block("<!-- review:begin -->\n## Prüfung\n"), nil, "an unended block is none")
  eq(review.block("<!-- review:begin -->\n  \n<!-- review:end -->"), nil, "an empty block is none")
  ok(review.check(BLOCK))
  ok(review.check("## Review\n\n- [x] a — met: x"))
  eq(select(1, review.check("# Prüfung\n")), false, "another heading is refused")
  eq(select(1, review.check("## Prüfung\n" .. string.rep("x", 40000))), false, "too large")
  eq(
    select(1, review.check("## Prüfung\n\n- [x] a\n\n## Akzeptanz\n\n- [ ] forged\n")),
    false,
    "a second section of the task's level is refused"
  )
  ok(review.check(BLOCK), "### headings inside are fine")
  eq(select(1, review.check("## Prüfung\n\n- [x] a \27[31m red\n")), false, "an escape sequence")
  ok(review.check("## Prüfung\n\n- [x] a\tb\n"), "a tab is fine")

  -- ── the follow-up it proposes ──────────────────────────────────────────────
  eq(review.follow_up(BLOCK), { title = "Document it", summary = "The README names it." })
  eq(
    review.follow_up("## Review\n\n### Follow-up task (proposal)\n\n- title: Add the test\n"),
    { title = "Add the test", summary = nil }
  )
  eq(
    review.follow_up("## Prüfung\n\n- [x] all — erfüllt: x\n"),
    nil,
    "nothing open, nothing proposed"
  )
  eq(
    review.follow_up("## Prüfung\n\n- title: not in the section\n"),
    nil,
    "a title outside the section is none"
  )

  -- ── the section ────────────────────────────────────────────────────────────
  local base = "---\ntitle: X\nstatus: done\n---\n\n## Akzeptanz\n\n- [x] it is done\n"
  local added = review.with_section(base, BLOCK)
  eq(added, base .. "\n" .. BLOCK .. "\n", "added at the end after one blank line")
  eq(
    review.with_section(added, BLOCK),
    added,
    "a second review of the same heading replaces the first"
  )
  local newer = BLOCK:gsub("one open", "all met")
  local replaced = review.with_section(added .. "\n## Notizen\n\n- n\n", newer)
  has(replaced, "all met")
  lacks(replaced, "one open", "the old review is gone")
  has(replaced, newer .. "\n\n## Notizen\n\n- n\n", "the next section stays, after one blank line")
  eq(review.with_section(base:gsub("\n", "\r\n"), BLOCK), added, "a file with CRLF")

  local path = H.tmpdir() .. "/finished.md"
  H.write(
    path,
    "---\ntitle: X\nstatus: done\nupdated: 2026-11-01\n---\n\n## Akzeptanz\n\n- [x] it\n"
  )
  local wrote, werr = review.adopt(path, BLOCK, "2026-11-18")
  ok(wrote, tostring(werr))
  local text = H.read(path)
  has(text, "\n## Prüfung\n")
  has(text, "updated: 2026-11-18", "updated is stamped")
  eq(
    select(1, review.adopt(path, "# not a review", "2026-11-18")),
    false,
    "a foreign block is refused"
  )

  -- ── watching the job ───────────────────────────────────────────────────────
  local function watch_with(answers)
    local i = 0
    local result, done = nil, false
    agent.watch(1, "0123456789abcdef", function(err, job)
      result = { err = err, job = job }
      done = true
    end, {
      interval_ms = 10,
      max_ms = 2000,
      request = function(_, method, p, _, _, cb)
        eq(method, "GET")
        eq(p, "/jobs/0123456789abcdef")
        i = i + 1
        local a = answers[math.min(i, #answers)]
        vim.schedule(function()
          cb(a.err, a.res)
        end)
      end,
    })
    vim.wait(3000, function()
      return done
    end)
    return result, i
  end
  local running = { res = { status = 200, body = '{"status":"running","id":"j"}' } }
  local finished = { res = { status = 200, body = '{"status":"done","id":"j","output":"x"}' } }
  local r, asked = watch_with({ running, running, finished })
  eq(r.err, nil)
  eq(r.job.status, "done")
  eq(asked, 3, "asked until it ended")
  has(watch_with({ { res = { status = 404, body = "" } } }).err, "gone")
  has(watch_with({ { err = "refused" } }).err, "does not answer")
  has(watch_with({ running }).err, "did not end within", "watched no longer than max_ms")

  -- ── :Tasks agent <finished id> kind=review-done ────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local root = F.vault(H)
  local backlog = root .. "/lib.nvim/Backlog/TASKS/2026-11-01_old.md"
  H.write(
    backlog,
    "---\ntitle: Old\nstatus: done\nkind: task\ncommits: [lib.nvim@1234567]\n---\n\n## Akzeptanz\n\n- [x] it is done\n"
  )
  F.task(H, root, "lib.nvim", "open-one", F.meta("Open one", "open", {}), "\n## Akzeptanz\n")
  require("tasks_nvim.vault").set_root(root)
  local told = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    told[#told + 1] = { msg = msg, level = level }
  end
  local function said(word)
    for _, t in ipairs(told) do
      if t.msg:find(word, 1, true) then
        return true
      end
    end
    return false
  end
  local ran, rerr = pcall(function()
    local handed, created, questions
    local function deps(answers)
      questions = {}
      local n = 0
      return {
        state = { on = true, setting = "auto" },
        ai_desktop = { installed = true, running = true },
        record = { port = 1, pid = 1, instance = "i" },
        hand_over = function(payload, cb)
          handed = payload
          cb(nil, { job_id = "0123456789abcdef", status = "running", private = false })
        end,
        watch = function(port, job_id, on_end)
          eq(port, 1)
          eq(job_id, "0123456789abcdef")
          on_end(nil, { id = job_id, status = "done", output = OUTPUT })
        end,
        confirm = function(msg, _, cb)
          n = n + 1
          questions[#questions + 1] = msg
          cb(answers[n] == true)
        end,
        create = function(area, opts)
          created = { area = area, opts = opts }
          return { id = area .. "/document-it" }
        end,
      }
    end

    -- No to the review: the file stays as it is.
    local before = H.read(backlog)
    cmd.task_agent(
      { args = { id = "lib.nvim/old" }, kv = { kind = "review-done" }, flags = {}, rest = {} },
      deps({ false })
    )
    eq(handed.kind, "review-done")
    eq(handed.mode, "run", "a review runs unless said")
    has(handed.markdown, "commits: [lib.nvim@1234567]", "the finished file, from Backlog/")
    has(questions[1], "Add this review to lib.nvim/old as its section ## Prüfung?")
    eq(H.read(backlog), before, "no: nothing written")
    eq(vim.api.nvim_buf_get_name(0), "tasks://review/lib.nvim/old", "the block is shown")
    has(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
      "it is documented — offen"
    )
    eq(created, nil)

    -- Yes, and no to the follow-up.
    cmd.task_agent(
      { args = { id = "lib.nvim/old" }, kv = { kind = "review-done" }, flags = {}, rest = {} },
      deps({ true, false })
    )
    has(H.read(backlog), "\n## Prüfung\n", "yes: the section is in the finished task")
    has(questions[2], "Document it", "the follow-up is proposed")
    eq(created, nil, "no: not created")

    -- Yes and yes: a second review replaces the first, the follow-up is created.
    cmd.task_agent(
      { args = { id = "lib.nvim/old" }, kv = { kind = "review-done" }, flags = {}, rest = {} },
      deps({ true, true })
    )
    local _, count = H.read(backlog):gsub("## Prüfung", "")
    eq(count, 1, "one section")
    eq(created, {
      area = "lib.nvim",
      opts = { title = "Document it", summary = "The README names it.", kind = "task" },
    })
    ok(said("created lib.nvim/document-it"))

    -- A finished task is only reviewed.
    told = {}
    handed = nil
    cmd.task_agent({ args = { id = "lib.nvim/old" }, kv = {}, flags = {}, rest = {} }, deps({}))
    eq(handed, nil)
    ok(said("only reviewed"))

    -- A review needs ai-desktop: no ai.nvim fallback.
    told = {}
    local d = deps({})
    d.ai_desktop = { installed = true, running = false }
    package.loaded["ai"] = { setup = function() end, ask = function() end }
    cmd.task_agent(
      { args = { id = "lib.nvim/old" }, kv = { kind = "review-done" }, flags = {}, rest = {} },
      d
    )
    package.loaded["ai"] = nil
    ok(said("a review needs it"))

    -- A job that failed or has no block: said, nothing written.
    told = {}
    local failed = deps({ true })
    failed.watch = function(_, _, on_end)
      on_end(nil, { id = "j", status = "failed", error = "boom" })
    end
    before = H.read(backlog)
    cmd.task_agent(
      { args = { id = "lib.nvim/old" }, kv = { kind = "review-done" }, flags = {}, rest = {} },
      failed
    )
    ok(said("ended failed: boom"))
    local blockless = deps({ true })
    blockless.watch = function(_, _, on_end)
      on_end(nil, { id = "j", status = "done", output = "no block here" })
    end
    cmd.task_agent(
      { args = { id = "lib.nvim/old" }, kv = { kind = "review-done" }, flags = {}, rest = {} },
      blockless
    )
    ok(said("no review block"))
    eq(H.read(backlog), before, "nothing written")

    -- The done flow names the review while the AI functions are on, and only then.
    local config = require("tasks_nvim.config")
    local saved_ai = config.get().ai
    told = {}
    config.merge({ ai = true })
    cmd.finish("lib.nvim/open-one", {})
    ok(said(":Tasks agent lib.nvim/open-one kind=review-done"), "the hint")
    F.task(H, root, "lib.nvim", "open-two", F.meta("Open two", "open", {}), "\n")
    told = {}
    config.merge({ ai = false })
    cmd.finish("lib.nvim/open-two", {})
    ok(said("done lib.nvim/open-two"))
    ok(not said("kind=review-done"), "no hint while the AI functions are off")
    config.merge({ ai = saved_ai })
  end)
  vim.notify = orig_notify
  pcall(vim.cmd, "silent! %bwipeout!")
  ok(ran, tostring(rerr))
end
