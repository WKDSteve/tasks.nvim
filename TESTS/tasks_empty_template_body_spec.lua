-- TESTS/tasks_empty_template_body_spec.lua -- `check` warns `empty-template-body` for an open task that still holds
-- the comments of the template; `tasks new --context/--acceptance/--notes` writes no comment beside real text.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local cli = require("tasks_nvim.cli")
  local index = require("tasks_nvim.index")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")

  local root = F.vault(H)
  local opts = { root = root, today = F.TODAY }
  local P = model.TEMPLATE_PLACEHOLDERS

  ---@param res table
  ---@return table<string, string> message per task id
  local function empties(res)
    local out = {}
    for _, f in ipairs(res.findings) do
      if f.code == "empty-template-body" then
        eq(f.severity, "warn", "a warning, never an error: old files must not turn the gate red")
        out[f.id] = f.message
      end
    end
    return out
  end

  -- what a fresh `tasks new` writes: all three comments
  assert(mutate.new("lib.nvim", { root = root, today = F.TODAY, title = "Bare", slug = "bare" }))
  -- an English body, only the notes comment left
  F.task(
    H,
    root,
    "cascade.nvim",
    "half",
    F.meta("Half", "open"),
    "\n## Context\n\nWhy.\n\n## Acceptance\n\n- [ ] done\n\n## Notes\n\n" .. P.en.notes .. "\n"
  )
  -- written in full: no warning
  F.task(
    H,
    root,
    "lib.nvim",
    "full",
    F.meta("Full", "open"),
    "\n## Kontext\n\nWarum.\n\n## Akzeptanz\n\n- [ ] fertig\n"
  )
  -- the comment quoted in a code block (a task about this very check): no warning
  F.task(
    H,
    root,
    "lib.nvim",
    "quoted",
    F.meta("Quoted", "open"),
    "\nThe check looks for:\n\n```\n" .. P.de.context .. "\n```\n"
  )
  -- a finished one in Backlog/ keeps its comments without a word
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-01-01_old.md",
    F.text(F.meta("Old", "done"), "\n## Kontext\n\n" .. P.de.context .. "\n")
  )
  for _, a in ipairs({ "lib.nvim", "cascade.nvim" }) do
    assert(index.write_area(a, opts))
  end

  local res = assert(check.run(opts))
  local got = empties(res)
  eq(vim.tbl_count(got), 2, vim.inspect(got))
  ok(got["lib.nvim/bare"], "a bare new task is warned about")
  ok(got["lib.nvim/bare"]:find("context, acceptance, notes", 1, true), got["lib.nvim/bare"])
  ok(got["cascade.nvim/half"]:find("section(s) notes", 1, true), tostring(got["cascade.nvim/half"]))
  eq(res.errors, 0, "the warning adds no error")
  eq(
    check.count_line(res.findings, "empty-template-body"),
    "empty-template-body: 2 task(s) in 2 area(s): cascade.nvim 1, lib.nvim 1"
  )
  eq(check.count_line(res.findings, "no-such-code"), nil)

  -- the CLI names the count per area; the run stays green (a warning)
  local said = {}
  local function put(s)
    said[#said + 1] = s
  end
  local code = cli.run({ "check", "--vault=" .. root }, { out = put, err = put })
  local text = table.concat(said, "\n")
  eq(code, 0, text)
  ok(text:find("empty-template-body: 2 task(s) in 2 area(s)", 1, true), text)

  -- `tasks new` with section text: no comment anywhere, the acceptance lines are checkboxes
  said = {}
  code = cli.run({
    "new",
    "lib.nvim",
    "Scripted",
    "--slug=scripted",
    "--context=From a script.",
    "--acceptance=first\nsecond",
    "--vault=" .. root,
  }, { out = put, err = put })
  eq(code, 0, table.concat(said, "\n"))
  local body = assert(H.read(root .. "/lib.nvim/ROADMAP/tasks/scripted.md"))
  eq(body:find("<!--", 1, true), nil, body)
  ok(body:find("## Kontext\n\nFrom a script.\n", 1, true), body)
  ok(body:find("- [ ] first\n- [ ] second", 1, true), body)
  ok(body:find("## Notizen", 1, true), "the empty section keeps its heading: " .. body)
  eq(model.template_placeholders_in(body), {})

  -- only --notes, in English: still no comment in the other two
  said = {}
  code = cli.run({
    "new",
    "cascade.nvim",
    "Noted",
    "--slug=noted",
    "--lang=en",
    "--notes=A note.",
    "--vault=" .. root,
  }, { out = put, err = put })
  eq(code, 0, table.concat(said, "\n"))
  body = assert(H.read(root .. "/cascade.nvim/ROADMAP/tasks/noted.md"))
  eq(body:find("<!--", 1, true), nil, body)
  ok(body:find("## Context", 1, true) and body:find("## Notes\n\nA note.", 1, true), body)

  -- an empty text is a usage error, not a silent placeholder
  said = {}
  code = cli.run(
    { "new", "lib.nvim", "Blank", "--context=  ", "--vault=" .. root },
    { out = put, err = put }
  )
  eq(code, 2, table.concat(said, "\n"))

  -- without any text the template stays as it was (the form and the bare `new` rely on it)
  eq(
    model.template_placeholders_in(mutate.body_sections({}, "de")),
    { "context", "acceptance", "notes" }
  )
  eq(model.template_placeholders_in(mutate.body_sections({ notes = "x" }, "de")), {})
end
