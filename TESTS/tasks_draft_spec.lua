-- TESTS/tasks_draft_spec.lua -- `:Tasks new --draft`: a free text becomes the fields of the new-task form
-- (`tasks_nvim.draft`): the check of a draft against the vault's values, the body of ai-desktop's job `draft-task`,
-- and the command with stand-ins of ai-desktop and ai.nvim. Nothing is created: the form is filled in only.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local draft = require("tasks_nvim.draft")

  local choices = {
    areas = { "lib.nvim", "tasks.nvim" },
    kinds = { "feature", "task", "bug" },
    tags = { "ui", "tasks-family" },
    categories = { "ux" },
    plans = { "ALL/ki-plan" },
  }

  -- ── the check: allowed values kept, others dropped, a wrong shape refused ──
  local d, err = draft.check({
    title = "  Knopf blau machen  ",
    area = "tasks.nvim",
    kind = "chore",
    prio = "2",
    effort = "XXL",
    value = 9,
    tags = { "ui", "made-up", "ui" },
    category = "ux",
    plan = "",
    summary = "Zeile eins.\nZeile zwei.",
    acceptance = { "- [ ] Der Knopf ist blau", "", "Kontrast reicht" },
  }, choices)
  eq(err, nil)
  eq(d.schema, "tasks-draft/1")
  eq(d.title, "Knopf blau machen", "trimmed")
  eq(d.area, "tasks.nvim")
  eq(d.kind, nil, "a kind of no vault is left out")
  eq(d.plan, nil, "an empty plan is none")
  eq(d.effort, nil)
  eq(d.value, nil)
  eq(d.prio, 2, "a digit as a string is taken")
  eq(d.tags, { "ui" })
  eq(d.category, { "ux" }, "one category as a string is a list of one")
  eq(d.acceptance, { "Der Knopf ist blau", "Kontrast reicht" })
  for _, word in ipairs({ "kind: chore", "tags: made-up", "effort: XXL", "value: 9" }) do
    ok(vim.tbl_contains(d.dropped, word), word)
  end

  for _, case in ipairs({
    { raw = "text", why = "not a JSON object" },
    { raw = { kind = "task" }, why = "no title" },
    { raw = { title = "" }, why = "empty" },
    { raw = { title = "a\nb" }, why = "control character" },
    { raw = { title = "x", prio = "high" }, why = "whole number" },
    { raw = { title = "x", tags = 3 }, why = "list of names" },
    { raw = { title = "x", acceptance = "one" }, why = "acceptance" },
    { raw = { title = "x", summary = "a\27[31m" }, why = "control character" },
    { raw = { title = "x\226\128\174y" }, why = "U+202E" },
    { raw = { title = string.rep("a", 400) }, why = "longer than" },
  }) do
    local bad, why = draft.check(case.raw, choices)
    eq(bad, nil, case.why)
    has(why, case.why)
  end
  ok(draft.check({ title = "x" }, choices), "a title alone is a draft")

  -- ── the block of an answer ─────────────────────────────────────────────────
  local plain = "Thinking.\n" .. draft.BEGIN .. '\n{"title": "A", "plan": null}\n' .. draft.END
  eq(draft.extract(plain, choices).title, "A")
  local fenced = draft.BEGIN
    .. '\n{"title": "old"}\n'
    .. draft.END
    .. "\n"
    .. draft.BEGIN
    .. '\n```json\n{"title": "B", "kind": "bug", "tags": []}\n```\n'
    .. draft.END
  local b = draft.extract(fenced, choices)
  eq(b.title, "B", "the last block")
  eq(b.kind, "bug")
  eq(b.tags, {})
  has(select(2, draft.extract("no block", choices)), "no draft block")
  has(select(2, draft.extract(draft.BEGIN .. '{"title": "x"}', choices)), "does not end")
  has(select(2, draft.extract(draft.BEGIN .. "{title: x}" .. draft.END, choices)), "not valid JSON")

  -- ── the body of the job, the prompt, the values of the form ───────────────
  local body = draft.payload("  Der Knopf\nsoll blau sein", "/vault/", {
    areas = { "a" },
    kinds = { "task" },
    tags = {},
    categories = { "ux" },
    plans = {},
  })
  eq(body.kind, "draft-task")
  eq(body.mode, "run")
  eq(body.area, "", "the area is not chosen yet")
  eq(body.private, true, "the strictest class")
  eq(body.task_id, "draft/new")
  eq(body.title, "Der Knopf")
  eq(body.choices.tags, nil, "an empty list is left out (Lua would send an object)")
  has(vim.json.encode(body), '"areas":["a"]')

  local prompt = draft.prompt("Der Knopf soll blau sein.", choices)
  has(prompt, "- area: lib.nvim, tasks.nvim")
  has(prompt, "- plan: ALL/ki-plan")
  has(prompt, draft.BEGIN)
  has(prompt, "~~~~text\nDer Knopf soll blau sein.\n~~~~")

  local given = draft.given(d)
  eq(given.title, "Knopf blau machen")
  eq(given.summary, "Zeile eins. Zeile zwei.", "the summary is one line of the form")
  eq(given.area, "tasks.nvim")
  eq(given.prio, "2")
  eq(given.tags, "ui")
  eq(given.category, "ux")
  eq(given.acceptance, "- [ ] Der Knopf ist blau\n- [ ] Kontrast reicht")

  -- The form takes the draft's acceptance into its section.
  local lines =
    require("tasks_nvim.form").template({ sections = { acceptance = "- [ ] a\n- [ ] b" } })
  local text = table.concat(lines, "\n")
  has(text, "## Akzeptanz\n\n- [ ] a\n- [ ] b\n")

  -- ── :Tasks new --draft ─────────────────────────────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local root = F.vault(H)
  require("tasks_nvim.vault").set_root(root)
  local told = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    told[#told + 1] = { msg = msg, level = level }
  end
  local function last()
    return told[#told] and told[#told].msg or ""
  end
  local ran, rerr = pcall(function()
    local on = { on = true, setting = "auto" }
    local running = { installed = true, running = true }
    local answer = {
      status = "done",
      draft = {
        schema = "tasks-draft/1",
        title = "Blauer Knopf",
        area = "lib.nvim",
        kind = "task",
        dropped = {},
      },
    }
    local handed, filled, confirmed_run
    local function deps(extra)
      return vim.tbl_extend("force", {
        state = on,
        ai_desktop = running,
        choices = choices,
        root = root,
        record = { port = 1, pid = 1, instance = "" },
        hand_over = function(payload, cb, hdeps)
          handed = payload
          ok(hdeps and type(hdeps.allow_foreground) == "function", "no focus right for a draft")
          cb(nil, { job_id = "0123456789abcdef", status = "running", private = true })
        end,
        watch = function(_, job_id, on_end)
          eq(job_id, "0123456789abcdef")
          on_end(nil, answer)
        end,
        form = function(g)
          filled = g
        end,
      }, extra or {})
    end

    -- :Tasks new --draft goes to task_new_draft (the area word is part of the text, not an area).
    local real, forwarded = cmd.task_new_draft, nil
    cmd.task_new_draft = function(ctx)
      forwarded = ctx
    end
    cmd.task_new({ args = { area = "Der" }, rest = { "Knopf" }, kv = {}, flags = { draft = true } })
    cmd.task_new_draft = real
    eq(forwarded and forwarded.args.area, "Der")
    handed, filled = nil, nil
    cmd.task_new_draft({
      args = { area = "Der" },
      rest = { "Knopf", "soll", "blau", "sein" },
      kv = {},
      flags = { draft = true },
    }, deps())
    eq(handed.markdown, "Der Knopf soll blau sein", "the words after --draft are the text")
    eq(handed.kind, "draft-task")
    eq(filled.title, "Blauer Knopf", "the draft fills the form")
    eq(filled.area, "lib.nvim")
    eq(filled.kind, "task")

    -- A draft whose area left the vault since: checked again here, left out; what ai-desktop left out is named too.
    answer.draft.area = "gone"
    answer.draft.dropped = { "plan: nowhere", 7 }
    filled = nil
    told = {}
    cmd.task_new_draft({ args = {}, rest = { "x" }, kv = {}, flags = { draft = true } }, deps())
    eq(filled.area, nil)
    has(told[#told - 1].msg, "plan: nowhere, area: gone")
    answer.draft.dropped = {}
    has(last(), "<C-s> creates the task")
    answer.draft.area = "lib.nvim"

    -- No draft: said, nothing filled in.
    filled = nil
    cmd.task_new_draft(
      { args = {}, rest = { "x" }, kv = {}, flags = { draft = true } },
      deps({
        watch = function(_, _, on_end)
          on_end(nil, { status = "done", draft_error = "the answer holds no draft block" })
        end,
      })
    )
    eq(filled, nil)
    has(last(), "no draft block; nothing filled in")

    -- A model that is not local: asked here first; no means nothing runs.
    local asked_msg
    cmd.task_new_draft(
      { args = {}, rest = { "x" }, kv = {}, flags = { draft = true } },
      deps({
        hand_over = function(_, cb)
          cb(nil, { job_id = "0123456789abcdef", status = "needs_confirmation", private = true })
        end,
        confirm = function(msg, _, cb)
          asked_msg = msg
          cb(false)
        end,
        confirm_run = function()
          confirmed_run = true
        end,
      })
    )
    has(asked_msg, "counts as private")
    eq(confirmed_run, nil, "no: nothing runs")
    filled = nil
    cmd.task_new_draft(
      { args = {}, rest = { "x" }, kv = {}, flags = { draft = true } },
      deps({
        hand_over = function(_, cb)
          cb(nil, { job_id = "0123456789abcdef", status = "needs_confirmation", private = true })
        end,
        confirm = function(_, _, cb)
          cb(true)
        end,
        confirm_run = function(_, _, cb)
          confirmed_run = true
          cb(nil)
        end,
      })
    )
    ok(confirmed_run, "yes: run with the person's confirmation")
    eq(filled.title, "Blauer Knopf")

    -- No text, AI off.
    told = {}
    cmd.task_new_draft({ args = {}, rest = {}, kv = {}, flags = { draft = true } }, deps())
    has(last(), "give a text")
    cmd.task_new_draft(
      { args = {}, rest = { "x" }, kv = {}, flags = { draft = true } },
      deps({ state = { on = false, setting = false } })
    )
    has(last(), "the AI functions are off")

    -- A selection is the text (and its ref goes with the form).
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "erste Zeile", "zweite Zeile", "dritte" })
    vim.api.nvim_set_current_buf(buf)
    handed = nil
    cmd.task_new_draft({
      args = {},
      rest = {},
      kv = {},
      flags = { draft = true },
      range = { range = 2, line1 = 1, line2 = 2 },
    }, deps())
    eq(handed.markdown, "erste Zeile\nzweite Zeile")

    -- Without ai-desktop: ai.nvim after a yes, its answer checked the same way.
    local prompt_sent
    filled = nil
    cmd.task_new_draft(
      { args = {}, rest = { "Notiz" }, kv = {}, flags = { draft = true } },
      deps({
        ai_desktop = { installed = false, running = false },
        ai_nvim = {
          ask = function(req, cb)
            prompt_sent = req.prompt
            cb(true, {
              text = draft.BEGIN
                .. '\n{"title": "Aus ai.nvim", "tags": ["ui", "nope"]}\n'
                .. draft.END,
            })
          end,
        },
        confirm = function(msg, _, cb)
          has(msg, "ai.nvim answers once instead")
          has(msg, "counts as private")
          cb(true)
        end,
      })
    )
    vim.wait(1000, function()
      return filled ~= nil
    end)
    has(prompt_sent, "~~~~text\nNotiz\n~~~~")
    eq(filled.title, "Aus ai.nvim")
    eq(filled.tags, "ui")
    has(
      table.concat(
        vim.tbl_map(function(t)
          return t.msg
        end, told),
        "\n"
      ),
      "tags: nope"
    )

    -- ai.nvim: no yes, nothing sent.
    prompt_sent = nil
    cmd.task_new_draft(
      { args = {}, rest = { "Notiz" }, kv = {}, flags = { draft = true } },
      deps({
        ai_desktop = { installed = false, running = false },
        ai_nvim = {
          ask = function(req)
            prompt_sent = req.prompt
          end,
        },
        confirm = function(_, _, cb)
          cb(false)
        end,
      })
    )
    eq(prompt_sent, nil)
    has(last(), "nothing sent")

    for _, t in ipairs(told) do
      lacks(t.msg, "Bearer")
    end
  end)
  vim.notify = orig_notify
  pcall(vim.cmd, "silent! %bwipeout!")
  ok(ran, tostring(rerr))

  -- ── the flag of the route ──────────────────────────────────────────────────
  local route
  for _, r in ipairs(require("tasks_nvim.ui.routes").routes({ flat = true })) do
    if table.concat(r.path, " ") == "new" then
      route = r
    end
  end
  ok(route, ":Tasks new is a route")
  local names = {}
  for _, f in ipairs(route.flags or {}) do
    names[#names + 1] = f.name
  end
  ok(vim.tbl_contains(names, "draft"), "--draft is a flag of :Tasks new")
  -- The composer checks the first word before it knows the flags: any word passes (`:Tasks new --draft Der Knopf`),
  -- and task_new checks the area itself when it is no draft.
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  ok(argtypes.validate("Der", route.args[1]), "a word of the text is no refused area")
  local told2 = {}
  local orig = vim.notify
  vim.notify = function(msg)
    told2[#told2 + 1] = msg
  end
  local fine, why =
    pcall(cmd.task_new, { args = { area = "nope" }, rest = { "x" }, kv = {}, flags = {} })
  vim.notify = orig
  ok(fine, tostring(why))
  has(told2[#told2] or "", "nope")
end
