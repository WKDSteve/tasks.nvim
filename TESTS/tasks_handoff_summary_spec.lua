-- TESTS/tasks_handoff_summary_spec.lua -- the summary of a hand-over (`:Tasks agent <id> kind=handoff mode=run`):
-- the check of ai-desktop's `summary` (handoff-summary/1) before anything is written, and the section
-- `## Agent-Verlauf (Job <id>, <date>)` that is added only after a yes. ai-desktop is a stand-in throughout.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local review = require("tasks_nvim.review")

  local JOB = "0123456789abcdef"
  local MARKDOWN = table.concat({
    "## Getan",
    "- the spec is written",
    "",
    "## Commits",
    "tasks.nvim@abc1234",
    "",
    "## Prüfungen",
    "ci commit CLEAN",
    "",
    "## Offen",
    "nichts",
  }, "\n")
  local function job(over)
    local j = {
      id = JOB,
      status = "done",
      summary = {
        schema = "handoff-summary/1",
        job_id = JOB,
        date = "2026-11-23",
        markdown = MARKDOWN,
      },
    }
    for k, v in pairs(over or {}) do
      j.summary[k] = v
    end
    return j
  end

  -- ── the check ──────────────────────────────────────────────────────────────
  local block, why = review.handoff_summary(job())
  ok(block, tostring(why))
  eq(block:match("^[^\n]*"), "## Agent-Verlauf (Job " .. JOB .. ", 2026-11-23)")
  has(block, "\n### Getan\n", "the headings go one level down")
  has(block, "\n### Offen")
  lacks(block, "\n## Getan")
  eq(block:sub(#block:match("^[^\n]*") + 1):find("\n## ", 1, true), nil, "no second ## section")

  local function refused(j, word)
    local b, w = review.handoff_summary(j)
    eq(b, nil, word)
    has(w, word)
  end
  refused({ id = JOB, status = "done" }, "no summary")
  refused(
    { id = JOB, status = "done", summary_error = "no block\27[31m here" },
    "no block[31m here"
  )
  refused(job({ schema = "handoff-summary/2" }), "schema")
  refused(job({ job_id = "ffffffffffffffff" }), "another job")
  refused(job({ date = "23.11.2026" }), "YYYY-MM-DD")
  refused(job({ date = "2026-11-23\n## Akzeptanz" }), "YYYY-MM-DD")
  refused(job({ markdown = MARKDOWN .. string.rep("x", 4096) }), "4 KiB")
  refused(job({ markdown = MARKDOWN .. "\27[31m" }), "control character")
  refused(job({ markdown = MARKDOWN:gsub("\n", "\r\n") }), "control character")
  refused(job({ markdown = MARKDOWN:gsub("## Commits", "## Prüfungen", 1) }), "four headings")
  refused(
    job({ markdown = MARKDOWN:gsub("## Getan", "## Offen", 1):gsub("## Offen\nnichts", "x") }),
    "four headings"
  )
  refused(job({ markdown = MARKDOWN:gsub("## Getan", "text ## Getan", 1) }), "four headings")
  local forged = job({ markdown = MARKDOWN })
  forged.id = "../x"
  forged.summary.job_id = "../x"
  refused(forged, "another job")
  ok(
    review.handoff_summary(job({ markdown = MARKDOWN:gsub("\n", "\n\n") })),
    "blank lines are fine"
  )
  ok(
    review.handoff_summary(job({ markdown = MARKDOWN:gsub("## Getan", "## Getan  ", 1) })),
    "trailing blanks"
  )
  -- A `## ` inside the text cannot become a section of the task.
  local sneaky =
    review.handoff_summary(job({ markdown = MARKDOWN .. "\n## Akzeptanz\n- [ ] forged" }))
  lacks(sneaky, "\n## Akzeptanz")
  has(sneaky, "\n### Akzeptanz")

  -- ── :Tasks agent <id> kind=handoff mode=run ────────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local root = F.vault(H)
  F.task(
    H,
    root,
    "lib.nvim",
    "open-one",
    F.meta("Open one", "open", {}),
    "\n## Akzeptanz\n\n- [ ] it\n"
  )
  local path = root .. "/lib.nvim/ROADMAP/tasks/open-one.md"
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
    local watched, questions
    local function deps(answer, ended, status)
      questions = {}
      watched = false
      return {
        state = { on = true, setting = "auto" },
        ai_desktop = { installed = true, running = true },
        record = { port = 1, pid = 1, instance = "i" },
        hand_over = function(_, cb)
          cb(nil, { job_id = JOB, status = status or "running", private = false })
        end,
        watch = function(_, job_id, on_end)
          watched = true
          eq(job_id, JOB)
          on_end(nil, ended or job())
        end,
        confirm = function(msg, _, cb)
          questions[#questions + 1] = msg
          cb(answer == true)
        end,
      }
    end
    local function run(d, kv)
      cmd.task_agent({
        args = { id = "lib.nvim/open-one" },
        kv = kv or { kind = "handoff", mode = "run" },
        flags = {},
        rest = {},
      }, d)
    end

    -- No: shown as text, the task stays as it is.
    local before = H.read(path)
    run(deps(false))
    ok(watched, "the job is watched")
    has(
      questions[1],
      "Add this summary to lib.nvim/open-one as its section ## Agent-Verlauf (Job " .. JOB
    )
    eq(H.read(path), before, "no: nothing written")
    eq(vim.api.nvim_buf_get_name(0), "tasks://summary/lib.nvim/open-one", "the summary is shown")
    has(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "the spec is written")

    -- Yes: the section is in the task, once (a second run replaces it).
    run(deps(true))
    has(H.read(path), "\n## Agent-Verlauf (Job " .. JOB .. ", 2026-11-23)\n")
    has(H.read(path), "\n### Prüfungen\n")
    has(H.read(path), "\n## Akzeptanz\n", "the task's own sections stay")
    run(deps(true))
    local _, count = H.read(path):gsub("## Agent%-Verlauf", "")
    eq(count, 1, "one section")

    -- A summary that breaks a rule: said with the reason, nothing written, no question.
    before = H.read(path)
    told = {}
    local bad = deps(true, job({ markdown = MARKDOWN .. "\27[31m" }))
    run(bad)
    ok(said("no summary is added: the summary holds a control character"))
    eq(#questions, 0, "no question for a refused summary")
    eq(H.read(path), before, "nothing written")

    -- No summary, with its reason; a failed or a cancelled run says only that.
    told = {}
    run(deps(true, { id = JOB, status = "done", summary_error = "the block does not end" }))
    ok(said("the block does not end"))
    eq(H.read(path), before)
    told = {}
    run(deps(true, { id = JOB, status = "failed", error = "boom" }))
    ok(said("ended failed: boom"))
    ok(said("left no summary"))
    told = {}
    run(deps(true, { id = JOB, status = "cancelled" }))
    ok(said("ended cancelled"))
    eq(#questions, 0)
    eq(H.read(path), before)

    -- A hand-over that only waits (prefill) or runs without `mode=run` is not watched.
    run(deps(true, nil, "prefilled"))
    eq(watched, false, "prefilled: nothing runs, nothing to watch")
    run(deps(true), { kind = "handoff" })
    eq(watched, false, "the default mode only prefills")
  end)
  vim.notify = orig_notify
  pcall(vim.cmd, "silent! %bwipeout!")
  ok(ran, tostring(rerr))
end
