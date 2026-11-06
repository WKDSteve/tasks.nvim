-- TESTS/tasks_scope_spec.lua -- the optional multi-value field `scope` (what a task touches).
-- Model, `new`, `set`, the contract entry and `hello`, and the `Other:` line of the form.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local form = require("tasks_nvim.form")
  local contract = require("tasks_nvim.contract")

  -- ── the model ──────────────────────────────────────────────────────────
  local function parse(front)
    return model.parse_text(
      "---\ntitle: A\nstatus: open\n" .. front .. "created: 2026-01-01\n---\n\nBody.\n",
      { path = "/v/a/ROADMAP/tasks/a.md", area = "a" }
    )
  end
  local good = parse("scope: [ui, multi-repo]\n")
  eq(good.scope, { "ui", "multi-repo" })
  eq(good.valid, true)
  eq(parse("").scope, {}, "optional: an old task has none")
  eq(parse("").valid, true)
  local bad = parse("scope: [ui, nope]\n")
  ok(vim.tbl_contains(bad.error_codes, "unknown-scope"), table.concat(bad.error_codes, ","))
  eq(bad.valid, false)
  eq(#model.SCOPES, 10)

  -- ── new and set ────────────────────────────────────────────────────────
  local root = fixture.build(H)
  -- the entry of the contract carries it, and only when the task names a scope
  local api = require("tasks_nvim.api")
  local alpha =
    vim.json.decode((api.call("task", '{"params":{"id":"lib.nvim/alpha"}}', { root = root })))
  eq(alpha.task.scope, { "ui", "usercmd" })
  local beta =
    vim.json.decode((api.call("task", '{"params":{"id":"lib.nvim/beta"}}', { root = root })))
  eq(beta.task.scope, nil)

  -- a hand-written file with an unknown word: the entry names the known ones only (the schema's enum), the word is a finding
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/odd-scope.md",
    "---\ntitle: Odd\nstatus: open\nscope: [ui, galaxy]\ncreated: 2026-01-01\n---\n\nBody.\n"
  )
  local odd =
    vim.json.decode((api.call("task", '{"params":{"id":"lib.nvim/odd-scope"}}', { root = root })))
  eq(odd.task.scope, { "ui" })
  eq(odd.task.valid, false)
  local opts = { root = root, today = "2026-03-01", index = false }
  local made, nerr =
    mutate.new("lib.nvim", vim.tbl_extend("force", opts, { title = "Scoped", scope = "ui,api" }))
  ok(made, tostring(nerr))
  has(H.read(made.path), "scope: [ui, api]")
  local _, e1 =
    mutate.new("lib.nvim", vim.tbl_extend("force", opts, { title = "Wrong", scope = "ui,galaxy" }))
  has(e1, "unknown scope 'galaxy'")

  local file = root .. "/lib.nvim/ROADMAP/tasks/alpha.md"
  ok(mutate.set("lib.nvim/alpha", { scope = "tests,docs" }, opts))
  has(H.read(file), "scope: [tests, docs]")
  local _, e2 = mutate.set("lib.nvim/alpha", { scope = "tests,galaxy" }, opts)
  has(e2, "unknown scope 'galaxy'")
  has(H.read(file), "scope: [tests, docs]", "a refused patch changes nothing")
  ok(mutate.set("lib.nvim/alpha", { scope = "" }, opts))
  ok(not H.read(file):find("scope:", 1, true), "an empty value takes it away")

  -- ── the contract ───────────────────────────────────────────────────────
  local hello = contract.hello()
  eq(hello.enums.scope, model.SCOPES)

  -- ── the form: ticks and the Other: line ────────────────────────────────
  local lines = form.template({ ticks = { scope = { "ui" } }, other = "api" })
  ok(vim.tbl_contains(lines, "## scope (several)"))
  ok(vim.tbl_contains(lines, "- [x] ui"))
  ok(vim.tbl_contains(lines, "Other: api"))

  local function validated(other, ticked)
    local l =
      form.template({ area = "lib.nvim", title = "T", ticks = { scope = ticked }, other = other })
    return form.validate(form.parse(l), { "lib.nvim" })
  end
  local v = validated("keymap, shiny new-thing", { "ui" })
  eq(v.opts.scope, "ui,keymap", "a scope word in Other joins the ticks")
  eq(v.opts.tags, "shiny, new-thing", "any other word goes to the tags")
  eq(#v.notes, 1)
  has(v.notes[1], "shiny, new-thing are no scope")
  local w = validated("ui", { "ui" })
  eq(w.opts.scope, "ui", "a word ticked and typed counts once")
  eq(#w.notes, 0)
  local u = validated("UI, Keymap, Shiny", { "ui" })
  eq(u.opts.scope, "ui,keymap", "a scope word counts in any case, stored in lower case")
  eq(u.opts.tags, "Shiny", "a tag stays as typed")
  local t = form.validate(
    form.parse(
      vim.list_extend(form.template({ area = "lib.nvim", title = "T", other = "oddity" }), {})
    ),
    { "lib.nvim" }
  )
  eq(t.opts.tags, "oddity")
  eq(t.opts.scope, nil)
end
