-- TESTS/tasks_learn_evidence_spec.lua -- the evidence of all learning paths (`learn.evidence`, `{for=t4}` in
-- `lernbaum`, `tasks.learn_evidence`, `tasks learn evidence`): which points are evidence, the stage they prove (read,
-- written back, refused as `path-bad-for`), the competence filter, the finished paths, the refusals. The document itself
-- is the golden `learn-evidence`.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local G = dofile(here .. "/contract_golden.lua")
  local api = require("tasks_nvim.api")
  local cli = require("tasks_nvim.cli")
  local learn = require("tasks_nvim.learn")
  local lernbaum = require("tasks_nvim.lernbaum")

  -- ── {for=…} ───────────────────────────────────────────────────────────────
  eq({ lernbaum.to_for("t4") }, { "t", 4 })
  eq({ lernbaum.to_for("P 3,5") }, { "p", 3.5 })
  eq({ lernbaum.to_for("x4") }, {})
  eq({ lernbaum.to_for("t9") }, {})
  eq({ lernbaum.to_for("t3.3") }, {})
  eq({ lernbaum.to_for("") }, {})

  local body = table.concat({
    "## Lernpunkte",
    "",
    "- [ ] Stufe {#s}",
    "  - [x] Nachweis: Klausur bestanden [Scan](https://example.org/k) {for=t4} {#k}",
    "  - [ ] aufgabe : eine Shell {for=p4} {xp=20} {#a}",
    "  - [ ] Ergebnis: {for=q1} {#bad}",
    "  - [ ] Kein Nachweis: steht nicht vorn {#no}",
    "  - [ ] Lesen {#read}",
    "",
  }, "\n")
  local tree = lernbaum.parse(body)
  eq(
    tree.by_key.k.label,
    "Nachweis: Klausur bestanden [Scan](https://example.org/k)",
    "the mark leaves the label"
  )
  eq({ tree.by_key.k.for_axis, tree.by_key.k.for_level }, { "t", 4 })
  eq(tree.by_key.a.xp, 20, "beside the other marks, in any order")
  local codes = vim.tbl_map(function(p)
    return p.code .. ":" .. tostring(p.key)
  end, tree.problems)
  eq(codes, { "path-bad-for:bad" })
  eq(lernbaum.render(tree), body, "the mark is written back as it was")
  lernbaum.set_state(tree, "a", "learned")
  has(lernbaum.render(tree), "  - [x] aufgabe : eine Shell {xp=20} {for=p4} {#a}")
  eq(
    vim.tbl_map(function(n)
      return n.key
    end, learn.evidence(tree)),
    { "k", "a", "bad" },
    "a word at the start with a colon, any case; not in the middle"
  )

  -- ── the document ──────────────────────────────────────────────────────────
  local root = F.vault(H)
  G.write_learn_paths(root)
  local function call(params)
    local text = api.call(
      "learn_evidence",
      { params = params or {} },
      { root = root, today = F.TODAY }
    )
    local doc = vim.json.decode(text)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end
  ok(
    vim.tbl_contains(
      vim.json.decode((api.call("hello", {}, { root = root }))).capabilities,
      "learn_evidence"
    )
  )
  local function ids(doc)
    return vim.tbl_map(function(i)
      return i.path .. "#" .. (i.key or i.index)
    end, doc.items)
  end
  eq(ids(call()), { "lib.nvim/prozesse#shell", "lib.nvim/signale#handler" })
  eq(#call({ include_done = true }).items, 3)
  local only = call({ competence = "lib.nvim/betriebssysteme" })
  eq(ids(only), { "lib.nvim/prozesse#shell" }, "the paths that serve the competence")
  eq(only.competence, "lib.nvim/betriebssysteme")
  eq(#call({ competence = "lib.nvim/netze" }).items, 0)
  eq(ids(call({ paths = { "lib.nvim/signale" } })), { "lib.nvim/signale#handler" })
  eq(select(2, call({ competence = "kein-id" })), "invalid_argument")
  eq(select(2, call({ areas = { "nope" } })), "not_found")
  -- a mark changed is a new rev
  local before = call()
  local file = root .. "/lib.nvim/ROADMAP/paths/signale.md"
  H.write(file, (H.read(file):gsub("%- %[ %] Ergebnis", "- [x] Ergebnis")))
  local after = call()
  ok(after.rev ~= before.rev)
  eq(after.items[2].state, "learned")

  -- check names a bad {for=…}
  H.write(file, (H.read(file):gsub("{for=t2}", "{for=z2}")))
  local chk =
    vim.json.decode((api.call("check", { params = { area = "lib.nvim" } }, { root = root })))
  local found = false
  for _, f in ipairs(chk.findings or {}) do
    found = found or f.code == "path-bad-for"
  end
  ok(found, "check reports path-bad-for")

  -- ── the command line ──────────────────────────────────────────────────────
  local function run(argv)
    local out, err = {}, {}
    vim.list_extend(argv, { "--vault=" .. root, "--today=" .. F.TODAY })
    local c = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return c, vim.trim(table.concat(out, "\n")), table.concat(err, "\n")
  end
  local c, out, err = run({ "learn", "evidence", "--competence=lib.nvim/betriebssysteme" })
  eq(c, 0, err)
  eq(out, "lib.nvim/prozesse\t#shell\topen\tP3\tNachweis: eine Shell in C")
  c, out = run({ "learn", "evidence", "--done", "--format=json" })
  eq(c, 0)
  eq(#vim.json.decode(out).items, 3)
  eq((run({ "learn", "evidence", "--competence=x" })), 2)
end
