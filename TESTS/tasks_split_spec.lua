-- TESTS/tasks_split_spec.lua -- splitting a plan (`:Tasks agent <plan-id> kind=split-plan`): the JSON drafts of
-- ai-desktop's answer, the buffer to tick them, and what the engine creates after a yes (a new phase only after its own
-- yes; a draft the engine refuses is refused alone). ai-desktop is a stand-in; the engine is the real one.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local review = require("tasks_nvim.review")

  local function draft(t)
    return vim.tbl_extend("force", {
      title = "Build the thing",
      area = "lib.nvim",
      kind = "feature",
      prio = 2,
      effort = "S",
      value = 4,
      phase = "build",
      summary = "It is built.",
      acceptance = { "it runs" },
    }, t or {})
  end
  local function block_of(doc)
    return "<!-- split:begin -->\n" .. vim.json.encode(doc) .. "\n<!-- split:end -->"
  end

  -- ── the drafts ─────────────────────────────────────────────────────────────
  local answer = "Split it.\n"
    .. block_of({
      phases = { { name = "build" }, { name = "polish", new = true } },
      tasks = { draft() },
    })
  local parsed = review.parse_split(review.block(answer, "split"))
  eq(parsed.phases, { { name = "build", new = false }, { name = "polish", new = true } })
  eq(parsed.drafts[1].title, "Build the thing")
  eq(parsed.drafts[1].after, {})
  eq(parsed.drafts[1].invalid, nil)
  ok(review.parse_split('```json\n{"tasks": [{"title": "A", "area": "x"}]}\n```'), "a fenced block")
  eq(select(2, review.parse_split("[1, 2]")), "the drafts are not one JSON object")
  eq(select(2, review.parse_split("not json")), "the drafts are not one JSON object")
  eq(select(2, review.parse_split('{"tasks": []}')), "the split proposes no task")
  local many = {}
  for i = 1, 31 do
    many[i] = draft({ title = "T" .. i })
  end
  has(select(2, review.parse_split(vim.json.encode({ tasks = many }))), "more than 30")
  local mixed = review.parse_split(vim.json.encode({
    tasks = {
      draft(),
      draft({ title = "two\nlines" }),
      draft({ prio = 2.5 }),
      { area = "lib.nvim" },
      draft({ area = "" }),
      draft({ acceptance = "not a list" }),
      "not a draft",
    },
  }))
  eq(mixed.drafts[1].invalid, nil, "a good draft stays good beside bad ones")
  has(mixed.drafts[2].invalid, "not one line")
  has(mixed.drafts[3].invalid, "whole number")
  has(mixed.drafts[4].invalid, "no title")
  has(mixed.drafts[5].invalid, "no area")
  has(mixed.drafts[6].invalid, "not a list")
  has(mixed.drafts[7].invalid, "not an object")

  -- ── :Tasks agent <plan-id> kind=split-plan ─────────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local root = F.vault(H)
  require("tasks_nvim.vault").set_root(root)
  local plans = require("tasks_nvim.plans")
  local made = assert(plans.new("lib.nvim", { title = "The plan", phases = { "build" } }))
  local plan_id = made.id
  F.task(
    H,
    root,
    "lib.nvim",
    "existing",
    F.meta("Existing work", "open", { { "plan", plan_id }, { "phase", "build" } }),
    "\n"
  )
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
    local handed, questions
    local DOC = {
      phases = { { name = "build" }, { name = "polish", new = true } },
      tasks = {
        draft({ title = "Build the thing" }),
        draft({ title = "Polish it", phase = "polish", after = { "#1" } }),
        draft({ title = "Wrong kind", kind = "chore" }),
        draft({ title = "Not ticked" }),
      },
    }
    local function deps(answers, doc)
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
        watch = function(_, job_id, on_end)
          on_end(nil, { id = job_id, status = "done", output = "Split.\n" .. block_of(doc or DOC) })
        end,
        confirm = function(msg, _, cb)
          n = n + 1
          questions[#questions + 1] = msg
          cb(answers[n] == true)
        end,
      }
    end
    local function split(d)
      cmd.task_agent(
        { args = { id = plan_id }, kv = { kind = "split-plan" }, flags = {}, rest = {} },
        d
      )
    end

    -- A plan is only split; a task is not split.
    cmd.task_agent({ args = { id = plan_id }, kv = {}, flags = {}, rest = {} }, deps({}))
    ok(said("is a plan; a plan is only split"))
    told = {}
    cmd.task_agent(
      { args = { id = "lib.nvim/existing" }, kv = { kind = "split-plan" }, flags = {}, rest = {} },
      deps({})
    )
    ok(said("split-plan names a plan"))

    -- What is sent: the plan with its tasks, to run.
    split(deps({ true, true }))
    eq(handed.kind, "split-plan")
    eq(handed.mode, "run")
    eq(handed.task_id, plan_id)
    has(handed.markdown, "title: The plan")
    has(handed.markdown, "## Tasks of this plan")
    has(
      handed.markdown,
      "- lib.nvim/existing (open, phase build): Existing work",
      "its tasks, against doubles"
    )

    -- The drafts in a buffer to tick; nothing created yet.
    local buf = vim.api.nvim_get_current_buf()
    eq(vim.api.nvim_buf_get_name(buf), "tasks://split/" .. plan_id)
    eq(vim.bo[buf].buftype, "acwrite")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    has(table.concat(lines, "\n"), "- [ ] 1. Build the thing")
    has(table.concat(lines, "\n"), "Phases: build, polish (new)")
    eq(
      require("tasks_nvim.scan").find("lib.nvim/build-the-thing"),
      nil,
      "nothing created before :w"
    )

    -- Tick 1, 2 and 3, write: a yes to create, a yes to the new phase.
    for i, line in ipairs(lines) do
      for _, n in ipairs({ 1, 2, 3 }) do
        if line:match("^%- %[ %] " .. n .. "%.") then
          lines[i] = line:gsub("%[ %]", "[x]", 1)
        end
      end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    told = {}
    vim.cmd("write")
    has(questions[1], "Create 3 task(s) in the plan " .. plan_id)
    has(questions[2], "polish", "the new phase is asked for")
    local first = require("tasks_nvim.scan").find("lib.nvim/build-the-thing")
    ok(first, "draft 1 created")
    eq(first.plan, plan_id)
    eq(first.phase, "build")
    eq(first.effort, "S")
    has(H.read(first.path), "- [ ] it runs", "its acceptance")
    has(H.read(first.path), "Entwurf aus der Zerlegung", "where it came from")
    local second = require("tasks_nvim.scan").find("lib.nvim/polish-it")
    ok(second, "draft 2 created")
    eq(second.after, { "lib.nvim/build-the-thing" }, "#1 became the id of draft 1")
    eq(require("tasks_nvim.plans").find(plan_id).phase_order, { "build", "polish" })
    eq(
      require("tasks_nvim.scan").find("lib.nvim/wrong-kind"),
      nil,
      "an invalid value refuses the draft"
    )
    ok(said("draft 3 (Wrong kind)"), "with its reason")
    eq(require("tasks_nvim.scan").find("lib.nvim/not-ticked"), nil, "not ticked, not created")
    local after_lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    has(after_lines, "- [+] 1. Build the thing  -> lib.nvim/build-the-thing")
    has(after_lines, "- [!] 3. Wrong kind")
    eq(vim.bo[buf].modified, false)

    -- No to a new phase: the drafts of that phase are refused, the others created.
    pcall(vim.cmd, "silent! %bwipeout!")
    told = {}
    split(deps({ true, false }, {
      tasks = { draft({ title = "Another build" }), draft({ title = "Ship it", phase = "ship" }) },
    }))
    buf = vim.api.nvim_get_current_buf()
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      lines[i] = line:gsub("^%- %[ %]", "- [x]", 1)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd("write")
    ok(require("tasks_nvim.scan").find("lib.nvim/another-build"), "the draft of a known phase")
    eq(require("tasks_nvim.scan").find("lib.nvim/ship-it"), nil)
    ok(said("its phase ship is not in the plan"))
    lacks(table.concat(require("tasks_nvim.plans").find(plan_id).phase_order, ","), "ship")

    -- Nothing ticked: nothing asked, nothing created.
    pcall(vim.cmd, "silent! %bwipeout!")
    told = {}
    split(deps({ true, true }, { tasks = { draft({ title = "Left alone" }) } }))
    vim.cmd("write")
    ok(said("nothing ticked"))
    eq(require("tasks_nvim.scan").find("lib.nvim/left-alone"), nil)

    -- No to creating: nothing.
    pcall(vim.cmd, "silent! %bwipeout!")
    split(deps({ false }, { tasks = { draft({ title = "Declined" }) } }))
    buf = vim.api.nvim_get_current_buf()
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      lines[i] = line:gsub("^%- %[ %]", "- [x]", 1)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd("write")
    eq(require("tasks_nvim.scan").find("lib.nvim/declined"), nil)
  end)
  vim.notify = orig_notify
  pcall(vim.cmd, "silent! %bwipeout!")
  ok(ran, tostring(rerr))
end
