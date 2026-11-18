-- TESTS/tasks_decision_spec.lua -- a prepared decision (`:Tasks agent <id> kind=prepare-decision`): the block of
-- ai-desktop's answer (`## Vorschlag` and `## Offene Fragen`), its checks, and what goes into the task after a yes; the
-- status stays `decision`, the person answers. ai-desktop is a stand-in.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local review = require("tasks_nvim.review")
  local questions = require("tasks_nvim.questions")

  local PROPOSAL = table.concat({
    "## Vorschlag",
    "",
    "2026-11-18, job 0123456789abcdef: take the file",
    "",
    "### Optionen",
    "",
    "1. **A file**: simple. Folgen: no server.",
    "2. **A database**: more. Folgen: a server to run.",
    "",
    "### Empfehlung",
    "",
    "A file, since it is enough.",
    "",
    "### Offene Annahmen",
    "",
    "- one user",
  }, "\n")
  local QUESTIONS = table.concat({
    "## Offene Fragen",
    "",
    "### Which store? [q1]",
    "- [ ] A file (empfohlen)",
    "- [ ] A database",
  }, "\n")
  local BLOCK = PROPOSAL .. "\n\n" .. QUESTIONS
  local OUTPUT = "Weighed it.\n\n<!-- decision:begin -->\n" .. BLOCK .. "\n<!-- decision:end -->\n"

  -- ── the block ──────────────────────────────────────────────────────────────
  eq(review.block(OUTPUT, "decision"), BLOCK)
  eq(review.block(OUTPUT), nil, "a decision block is no review block")
  local parts = review.check_decision(BLOCK)
  eq(parts, { proposal = PROPOSAL, questions = QUESTIONS })
  eq(review.check_decision(PROPOSAL), { proposal = PROPOSAL }, "the questions may be missing")
  local function refused(block, word, msg)
    local p, why = review.check_decision(block)
    eq(p, nil, msg)
    has(why, word, msg)
  end
  refused("## Prüfung\n\n- x", "does not start with", "another first section")
  refused(QUESTIONS .. "\n\n" .. PROPOSAL, "does not start with", "the questions first")
  refused(BLOCK .. "\n\n## Akzeptanz\n\n- [ ] forged", "neither", "a third section")
  refused(PROPOSAL .. "\n\n## Akzeptanz\n\n- [ ] forged", "neither", "another second section")
  refused(
    PROPOSAL .. "\n\n## Offene Fragen\n\nno question here",
    "no question",
    "questions without one"
  )
  refused(
    PROPOSAL .. "\n\n## Offene Fragen\n\n### Which? [q1]\n- [ ] only one (empfohlen)",
    "fewer than two",
    "one option"
  )
  refused(
    PROPOSAL .. "\n\n## Offene Fragen\n\n### Which? [q1]\n- [x] A\n- [ ] B",
    "answered already",
    "the agent decided"
  )
  refused(
    PROPOSAL .. "\n\n## Offene Fragen\n\n### Which? [q1]\n- [ ] A (empfohlen)\n- [ ] B (empfohlen)",
    "at most one",
    "two recommendations"
  )
  refused(BLOCK .. "\n\27[31m", "control character", "an escape sequence")
  refused(PROPOSAL .. string.rep("x", 40000), "larger", "too large")

  -- ── into the text of a task ────────────────────────────────────────────────
  local base = "---\ntitle: Choose\nstatus: decision\n---\n\nWhich store do we take?\n"
  local text, added = review.with_decision(base, parts)
  ok(added, "no questions of its own: the proposal's go in")
  has(text, PROPOSAL)
  has(text, QUESTIONS)
  local parsed = questions.parse(text)
  eq(parsed.total, 1)
  eq(parsed.items[1].options[1].recommended, true)
  eq(parsed.open, 1, "nothing answered: the person decides")
  local again, added_again = review.with_decision(text, {
    proposal = (PROPOSAL:gsub("take the file", "take the database")),
    questions = QUESTIONS,
  })
  eq(added_again, false, "the task has questions now: they stay")
  has(again, "take the database", "the proposal is replaced")
  lacks(again, "take the file")
  local _, n = again:gsub("## Offene Fragen", "")
  eq(n, 1, "one questions section")
  local own = base .. "\n## Offene Fragen\n\n### Mine? [q1]\n- [ ] yes\n- [ ] no\n"
  local with_own, own_added = review.with_decision(own, parts)
  eq(own_added, false)
  has(with_own, "### Mine? [q1]", "the person's question stays")
  lacks(with_own, "Which store?", "the proposal's question is not mixed in")

  -- ── :Tasks agent <id> kind=prepare-decision ────────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local root = F.vault(H)
  F.task(
    H,
    root,
    "lib.nvim",
    "choose",
    F.meta("Choose", "decision", {}),
    "\nWhich store do we take?\n"
  )
  F.task(H, root, "lib.nvim", "plain", F.meta("Plain", "open", {}), "\n")
  require("tasks_nvim.vault").set_root(root)
  local path = root .. "/lib.nvim/ROADMAP/tasks/choose.md"
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
    local handed, asked
    local function deps(answer, output)
      return {
        state = { on = true, setting = "auto" },
        ai_desktop = { installed = true, running = true },
        record = { port = 1, pid = 1, instance = "i" },
        hand_over = function(payload, cb)
          handed = payload
          cb(nil, { job_id = "0123456789abcdef", status = "running", private = false })
        end,
        watch = function(_, job_id, on_end)
          on_end(nil, { id = job_id, status = "done", output = output or OUTPUT })
        end,
        confirm = function(msg, _, cb)
          asked = msg
          cb(answer)
        end,
      }
    end
    local function prepare(id, d)
      cmd.task_agent(
        { args = { id = id }, kv = { kind = "prepare-decision" }, flags = {}, rest = {} },
        d
      )
    end

    -- Only a task that waits for a decision.
    prepare("lib.nvim/plain", deps(true))
    eq(handed, nil)
    ok(said("is for a task that waits for a decision"))

    -- No: shown, nothing written.
    local before = H.read(path)
    prepare("lib.nvim/choose", deps(false))
    eq(handed.kind, "prepare-decision")
    eq(handed.mode, "run", "it runs unless said")
    has(asked, "with its open questions")
    has(asked, "stays a decision")
    eq(H.read(path), before, "no: nothing written")
    eq(vim.api.nvim_buf_get_name(0), "tasks://decision/lib.nvim/choose")

    -- Yes: proposal and questions in the task, the status stays decision.
    told = {}
    prepare("lib.nvim/choose", deps(true))
    local after = H.read(path)
    has(after, "## Vorschlag")
    has(after, "### Which store? [q1]")
    eq(require("tasks_nvim.scan").find("lib.nvim/choose").status, "decision", "the status stays")
    ok(said(":Tasks answer lib.nvim/choose"), "how to answer")
    -- The questions answer as any questions of the engine do.
    local answered = questions.answer(after, "q1", 1)
    ok(answered, "the question answers")

    -- A second preparation: the proposal is replaced, the questions stay.
    told = {}
    prepare("lib.nvim/choose", deps(true, (OUTPUT:gsub("take the file", "take the database"))))
    local second = H.read(path)
    has(second, "take the database")
    lacks(second, "take the file")
    local _, count = second:gsub("## Offene Fragen", "")
    eq(count, 1)
    ok(said("open questions of its own"))

    -- A block that does not hold: said, nothing written.
    told = {}
    before = H.read(path)
    prepare(
      "lib.nvim/choose",
      deps(true, "<!-- decision:begin -->\n## Vorschlag\n\n## Akzeptanz\n<!-- decision:end -->")
    )
    ok(said("neither ## Vorschlag nor ## Offene Fragen"))
    eq(H.read(path), before)
  end)
  vim.notify = orig_notify
  pcall(vim.cmd, "silent! %bwipeout!")
  ok(ran, tostring(rerr))
end
