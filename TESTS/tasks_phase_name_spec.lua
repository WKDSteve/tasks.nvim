-- TESTS/tasks_phase_name_spec.lua -- a phase that is no kebab-case word is refused with the same message everywhere:
-- the word, the first character that is not allowed, the rule and a word that would do (`vault.slug_error`); the write
-- door carries the suggestion in `error.details`.

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local vault = require("tasks_nvim.vault")
  local mutate = require("tasks_nvim.mutate")
  local plans = require("tasks_nvim.plans")
  local model = require("tasks_nvim.model")
  local ops = require("tasks_nvim.ops")
  local cli = require("tasks_nvim.cli")

  local RULE = "(only a-z, 0-9 and single hyphens)"

  -- ── the message and the suggestion ──
  for _, case in ipairs({
    {
      "einführung",
      "phase 'einführung': 'ü' is not allowed " .. RULE .. "; try 'einfuehrung'",
      "ü",
      "einfuehrung",
    },
    { "Testen", "phase 'Testen': 'T' is not allowed " .. RULE .. "; try 'testen'", "T", "testen" },
    {
      "go live",
      "phase 'go live': a space is not allowed " .. RULE .. "; try 'go-live'",
      " ",
      "go-live",
    },
    {
      "abschluss-",
      "phase 'abschluss-': a hyphen at the end is not allowed " .. RULE .. "; try 'abschluss'",
      "-",
      "abschluss",
    },
    { "", "phase '': an empty word is not allowed " .. RULE, nil, nil },
    { "-a", "phase '-a': a hyphen at the start is not allowed " .. RULE .. "; try 'a'", "-", "a" },
    {
      "a--b",
      "phase 'a--b': a double hyphen is not allowed " .. RULE .. "; try 'a-b'",
      "-",
      "a-b",
    },
    { "Große_Straße", nil, "G", "grosse-strasse" },
    { "!!!", "phase '!!!': '!' is not allowed " .. RULE, "!", nil },
  }) do
    local word, message, char, suggestion = case[1], case[2], case[3], case[4]
    local got, details = vault.slug_error("phase", word)
    if message then
      eq(got, message, word)
    end
    eq(details.field, "phase", word)
    eq(details.value, word, word)
    eq(details.char, char, word)
    eq(details.suggestion, suggestion, word)
  end
  eq({ vault.slug_error("phase", "einfuehrung") }, {}, "a kebab-case word is no error")
  -- a stray byte that is no UTF-8 is the character at fault, shown as \xNN, not skipped
  has(vault.slug_error("phase", "a\255b"), "'\\xFF' is not allowed")
  -- the slug of a new task is made by the same folding
  eq(mutate.slugify("Einführung in Größen"), "einfuehrung-in-groessen")

  local root = F.vault(H)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local WANT = "phase 'einführung': 'ü' is not allowed " .. RULE .. "; try 'einfuehrung'"

  -- ── the engine functions ──
  local _, perr, pinfo = plans.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    title = "Roll out",
    phases = "abstimmungen, testen, einführung",
  })
  eq(perr, WANT, "plan_new names the one word that fails, not all of them")
  eq(pinfo.code, "invalid_argument")
  eq(pinfo.details.suggestion, "einfuehrung")
  local _, jerr = plans.new(
    "lib.nvim",
    { root = root, today = F.TODAY, kind = "project", title = "Big", phases = { "einführung" } }
  )
  eq(jerr, WANT, "project_new")
  local _, nerr, ninfo =
    mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "T", phase = "einführung" }))
  eq(nerr, WANT, "new --phase")
  eq(ninfo.details.suggestion, "einfuehrung")
  local _, serr, sdetails = mutate.check_patch({ phase = "einführung" }, { root = root })
  eq(serr, WANT, "set phase=")
  eq(sdetails.suggestion, "einfuehrung")

  -- ── check: a file with such a phase ──
  local task = model.parse_text(
    "---\ntitle: T\nstatus: open\nphase: einführung\n---\n\nSummary.\n",
    { path = root .. "/lib.nvim/ROADMAP/tasks/t.md", area = "lib.nvim" }
  )
  has(table.concat(task.errors, "\n"), WANT)
  local plan = plans.parse(
    "---\ntitle: P\nstatus: doing\nphase_order: [testen, einführung]\n---\n\nGoal.\n",
    { path = root .. "/lib.nvim/ROADMAP/plans/p.md", area = "lib.nvim" }
  )
  ok(not plan.valid)
  has(
    table.concat(plan.errors, "\n"),
    "phase_order 'einführung': 'ü' is not allowed " .. RULE .. "; try 'einfuehrung'"
  )

  -- ── the write door: the suggestion in error.details ──
  local function one(op)
    local doc, err = ops.run({ ops = { op } }, { root = root, today = F.TODAY })
    assert(doc, vim.inspect(err, { newline = " ", indent = "" }))
    eq(doc.kind, "tasks.result")
    return doc.results[1]
  end
  local function refused(entry, what)
    eq(entry.ok, false, what)
    eq(entry.error.code, "invalid_argument", what)
    eq(entry.error.message, WANT, what)
    eq(entry.error.details.field, "phase", what)
    eq(entry.error.details.value, "einführung", what)
    eq(entry.error.details.char, "ü", what)
    eq(entry.error.details.suggestion, "einfuehrung", what)
  end
  refused(
    one({ op = "plan_new", area = "lib.nvim", title = "P", phases = { "testen", "einführung" } }),
    "plan_new"
  )
  refused(
    one({ op = "project_new", area = "lib.nvim", title = "J", phases = { "einführung" } }),
    "project_new"
  )
  refused(
    one({ op = "new", area = "lib.nvim", title = "T", fields = { phase = "einführung" } }),
    "new"
  )
  local made = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Some task" })))
  refused(one({ op = "set", id = made.id, patch = { phase = "einführung" } }), "set")
  local p = one({ op = "plan_new", area = "lib.nvim", title = "Good plan", phases = { "a", "b" } })
  eq(p.ok, true, vim.inspect(p))
  refused(
    one({ op = "plan_set", id = p.id, patch = { phase_order = { "a", "einführung" } } }),
    "plan_set phase_order"
  )
  local j = one({ op = "project_new", area = "lib.nvim", title = "Good project", phases = { "x" } })
  eq(j.ok, true, vim.inspect(j))
  local p2 = one({ op = "plan_new", area = "lib.nvim", title = "Staged", project = j.id })
  eq(p2.ok, true, vim.inspect(p2))
  refused(one({ op = "plan_set", id = p2.id, patch = { phase = "einführung" } }), "plan_set phase")

  -- ── the CLI prints the same message ──
  local err = {}
  local code = cli.run(
    { "plan-new", "lib.nvim", "CLI plan", "--phases=testen,einführung", "--vault=" .. root },
    {
      out = function() end,
      err = function(t)
        err[#err + 1] = t
      end,
    }
  )
  ok(code ~= 0)
  has(table.concat(err), WANT)
end
