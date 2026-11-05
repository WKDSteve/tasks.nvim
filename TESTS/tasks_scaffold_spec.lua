-- TESTS/tasks_scaffold_spec.lua -- the acceptance scaffold: fixed lines by kind, category and scope (model), the block of
-- the :Tasks new form that follows the ticks, the severity rule and the lines in the body of the new task.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local model = require("tasks_nvim.model")
  local form = require("tasks_nvim.form")

  local function ids(rows)
    return vim.tbl_map(function(r)
      return r.id
    end, rows)
  end

  -- ── the model ──────────────────────────────────────────────────────────
  eq(model.scaffold({ kind = "task" }), {}, "a plain task has no scaffold")
  eq(ids(model.scaffold({ kind = "bug" })), { "repro", "regression-test", "version" })
  eq(
    ids(model.scaffold({ kind = "bug", category = { "bug", "security" } })),
    { "repro", "regression-test", "version", "proof-test", "rule-id", "no-details" },
    "the rows of kind and category are joined, each id once"
  )
  eq(ids(model.scaffold({ kind = "idea" })), { "question", "result-format" })
  eq(ids(model.scaffold({ kind = "task", category = { "refactor", "ci" } })), { "caller-impact" })
  eq(
    ids(model.scaffold({ kind = "task", category = { "ruleset" } })),
    { "ruleset-id", "ruleset-class", "ruleset-evidence", "ruleset-gate" }
  )
  eq(
    ids(model.scaffold({ kind = "task", scope = { "multi-repo" } })),
    { "repos-order", "engine-lock" }
  )
  eq(
    ids(model.scaffold({ kind = "task", scope = { "api" } })),
    { "api-types", "api-docs", "api-example", "api-compat" }
  )

  -- scenario 1: a feature with bindings gets the lines of usercmd, keymap, config, docs and tests (scope order)
  local s1 = model.scaffold({ kind = "feature", category = { "bindings" } })
  eq(ids(s1), { "usercmd", "keymap", "config", "docs", "spec" })
  eq(ids(model.scaffold({ kind = "feature", category = { "ux" } })), ids(s1), "ux counts as well")
  eq(model.scaffold({ kind = "task", category = { "bindings" } }), {}, "only a feature gets them")
  eq(
    ids(model.scaffold({ kind = "feature", category = { "bindings" }, scope = { "api", "docs" } })),
    {
      "usercmd",
      "keymap",
      "config",
      "api-types",
      "api-docs",
      "api-example",
      "api-compat",
      "docs",
      "spec",
    },
    "scope rows come in SCOPES order, a row two causes once"
  )

  -- the language of the headings
  eq(model.scaffold({ kind = "bug" }, "en")[1].text, "Steps to reproduce described")
  eq(model.scaffold({ kind = "bug" }, "de")[1].text, "Reproduktion beschrieben")
  eq(model.scaffold({ kind = "bug" })[1].text, "Reproduktion beschrieben", "de by default")

  -- every row has both languages, and every word of the table is a word of its list
  for _, group in ipairs({
    { "kind", model.KINDS },
    { "category", model.CATEGORIES },
    { "scope", model.SCOPES },
  }) do
    for word, rows in pairs(model.SCAFFOLD[group[1]]) do
      ok(vim.tbl_contains(group[2], word), group[1] .. " " .. word .. " is not in its list")
      for _, row in ipairs(rows) do
        ok(row.de ~= "" and row.en ~= "" and row.id ~= "", word)
      end
    end
  end

  -- severity only fits a bug or security task
  ok(model.severity_applies({ kind = "bug" }))
  ok(model.severity_applies({ kind = "task", category = { "docs", "security" } }))
  ok(not model.severity_applies({ kind = "feature", category = { "ux" } }))
  ok(not model.severity_applies({}))

  -- ── the contract ───────────────────────────────────────────────────────
  local hello = require("tasks_nvim.contract").hello()
  eq(hello.enums.scaffold.kind.bug[1].id, "repro")
  eq(hello.enums.scaffold.implied[1].kind, "feature")

  -- ── the form ───────────────────────────────────────────────────────────
  local function block(lines)
    local out, on = {}, false
    for _, l in ipairs(lines) do
      if l:match("^## scaffold") then
        on = true
      elseif on and l:match("^%s*[-*]%s+%[.%]") then
        out[#out + 1] = l
      elseif on then
        break
      end
    end
    return out
  end

  local plain = form.template({ lang = "en" })
  ok(vim.tbl_contains(plain, "## scaffold (several)"), "the block is in a fresh form")
  eq(block(plain), {}, "kind task: nothing offered")
  ok(
    vim.tbl_contains(plain, "## severity (one, only for bug and security)"),
    "severity says it does not fit"
  )

  local fresh =
    form.template({ lang = "en", ticks = { kind = "feature", category = { "bindings" } } })
  eq(#block(fresh), 5)
  has(block(fresh)[2], "- [x] Mapping only through the config, no default")

  -- ticking a bug follows: the rows change and severity fits
  local lines = form.template({ lang = "en", ticks = { kind = "feature" } })
  local at
  for i, l in ipairs(lines) do
    if l:match("^## kind") then
      for j = i + 1, #lines do
        if lines[j] == "- [ ] bug" then
          at = j
          break
        end
      end
      break
    end
  end
  local toggled = form.toggle(lines, at)
  local refreshed = form.refresh(toggled, "en")
  eq(#block(refreshed), 3, "repro, regression test, version")
  ok(vim.tbl_contains(refreshed, "## severity (one)"), "severity fits a bug")
  eq(form.refresh(refreshed, "en"), nil, "nothing to do when nothing changed")

  -- an unticked row stays unticked while the choice changes; a new row comes ticked
  local with_off = vim.deepcopy(refreshed)
  for i, l in ipairs(with_off) do
    if l:match("%[x%] Regression test") then
      with_off[i] = (l:gsub("%[x%]", "[ ]"))
    end
  end
  for i, l in ipairs(with_off) do
    if l:match("^## category") then
      for j = i + 1, #with_off do
        if with_off[j] == "- [ ] security" then
          with_off[j] = "- [x] security"
          break
        end
      end
      break
    end
  end
  local again = block(form.refresh(with_off, "en"))
  eq(#again, 6)
  ok(vim.tbl_contains(again, "- [ ] Regression test that fails without the fix"), "kept unticked")
  ok(vim.tbl_contains(again, "- [x] A test proves the gap"), "new row comes ticked")

  -- a line the person typed into the block is kept, and goes to the Akzeptanz section like the rows
  local mine = vim.deepcopy(refreshed)
  for i, l in ipairs(mine) do
    if l:match("^## scaffold") then
      table.insert(mine, i + 1, "- [x] My own check")
      break
    end
  end
  local kept = form.refresh(mine, "en")
  mine = kept or mine
  ok(vim.tbl_contains(mine, "- [x] My own check"), "kept after a refresh")
  eq(#block(mine), 4, "the three rows and the own line")

  -- ── validate: the ticked rows open the Akzeptanz section ───────────────
  local function validated(l)
    local filled = vim.deepcopy(l)
    for i, line in ipairs(filled) do
      if line == "Area: " then
        filled[i] = "Area: lib.nvim"
      elseif line == "Title: " then
        filled[i] = "Title: T"
      end
    end
    return form.validate(form.parse(filled), { "lib.nvim" }, nil, "en")
  end
  local v = validated(
    form.template({ lang = "en", ticks = { kind = "feature", category = { "bindings" } } })
  )
  has(v.opts.body, "- [ ] User command with completion and help tag")
  has(v.opts.body, "- [ ] Spec added")
  eq(#v.notes, 0)

  -- a row unticked in the form is not written; the person's own acceptance text follows the rows
  local own =
    form.template({ lang = "en", ticks = { kind = "feature", category = { "bindings" } } })
  for i, l in ipairs(own) do
    if l:match("%[x%] Spec added") then
      own[i] = "- [ ] Spec added"
    end
    if l == "## Acceptance" then
      own[i + 1] = "Own line"
    end
  end
  local v2 = validated(own)
  ok(not v2.opts.body:find("- [ ] Spec added", 1, true), "unticked: gone")
  local first = v2.opts.body:find("- [ ] Mapping only through the config", 1, true)
  local last = v2.opts.body:find("- [ ] Own line", 1, true)
  ok(first and last and first < last, "the rows come first")

  -- a plain task writes no scaffold (the engine's own sections are used)
  eq(validated(form.template({ lang = "en" })).opts.body, nil)

  -- severity on a task it does not fit is told, not refused
  local sev =
    validated(form.template({ lang = "en", ticks = { kind = "feature", severity = "high" } }))
  eq(sev.opts.severity, "high")
  has(sev.notes[1], "severity is meant for bug or security")
end
