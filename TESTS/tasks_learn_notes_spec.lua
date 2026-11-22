-- TESTS/tasks_learn_notes_spec.lua -- the notes, links and images of the points of all learning paths
-- (`learn.notes`, `tasks.learn_notes`, `tasks learn notes`): which points are hits, the kind, the search without case
-- over label, note and link, areas and paths, the finished paths, the limit, the refusals. The document itself is the
-- golden `learn-notes`.
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

  -- ── pure ──────────────────────────────────────────────────────────────────
  local tree = lernbaum.parse(table.concat({
    "## Lernpunkte",
    "",
    "- [ ] Stufe Über {#s}",
    "  > Eine Notiz zur Stufe.",
    "  - [x] [Handbuch](https://example.org/MANUAL) {#m}",
    "  - [ ] Bild ![x](assets/a.png) {#b}",
    "  - [ ] Nichts {#n}",
    "",
  }, "\n"))
  local function keys(nodes)
    return vim.tbl_map(function(n)
      return n.key
    end, nodes)
  end
  eq(
    keys(learn.notes(tree)),
    { "s", "m", "b" },
    "a stage with a note is a hit; a bare point is none"
  )
  eq(keys(learn.notes(tree, { kind = "note" })), { "s" })
  eq(keys(learn.notes(tree, { kind = "link" })), { "m" })
  eq(keys(learn.notes(tree, { kind = "image" })), { "b" })
  eq(keys(learn.notes(tree, { query = learn.fold("manual") })), { "m" }, "the link, without case")
  eq(
    keys(learn.notes(tree, { query = learn.fold("ÜBER") })),
    { "s" },
    "the label, folded beyond ASCII"
  )
  eq(keys(learn.notes(tree, { query = learn.fold("notiz zur") })), { "s" }, "the note")
  eq(keys(learn.notes(tree, { query = "nirgends" })), {})
  eq(keys(learn.notes(tree, { kind = "image", query = "handbuch" })), {})

  -- ── the document ──────────────────────────────────────────────────────────
  local root = F.vault(H)
  G.write_learn_paths(root)
  local function call(params)
    local text = api.call(
      "learn_notes",
      { params = params or {} },
      { root = root, today = F.TODAY }
    )
    local doc = vim.json.decode(text)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end
  ok(
    vim.tbl_contains(
      vim.json.decode((api.call("hello", {}, { root = root }))).capabilities,
      "learn_notes"
    )
  )
  local function ids(doc)
    return vim.tbl_map(function(i)
      return i.path .. "#" .. i.index
    end, doc.items)
  end
  local all = call()
  eq(
    ids(all),
    { "lib.nvim/prozesse#5", "lib.nvim/signale#1" },
    "open paths only without include_done"
  )
  eq(all.total, 2)
  eq(all.truncated, false)
  eq(#call({ include_done = true }).items, 3)
  eq(ids(call({ include_done = true, query = "PIPEFAIL" })), { "lib.nvim/shell#1" })
  eq(ids(call({ kind = "image" })), { "lib.nvim/signale#1" })
  eq(ids(call({ paths = { "lib.nvim/signale" } })), { "lib.nvim/signale#1" })
  eq(#call({ areas = { "cascade.nvim" } }).items, 0)
  eq(#call({ areas = { "cascade.nvim", "lib.nvim" } }).items, 2)
  local cut = call({ limit = 1 })
  eq(#cut.items, 1)
  eq(cut.total, 2)
  eq(cut.truncated, true)
  -- a note changed is a new rev
  local file = root .. "/lib.nvim/ROADMAP/paths/signale.md"
  H.write(file, (H.read(file):gsub("APUE", "Stevens")))
  ok(call().rev ~= all.rev)
  eq(ids(call({ query = "stevens" })), { "lib.nvim/signale#1" })

  eq(select(2, call({ kind = "video" })), "invalid_argument")
  eq(select(2, call({ limit = 0 })), "invalid_argument")
  eq(select(2, call({ limit = 501 })), "invalid_argument")
  eq(select(2, call({ query = ("x"):rep(201) })), "invalid_argument")
  eq(select(2, call({ areas = { "nope" } })), "not_found")

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
  local c, out, err = run({ "learn", "notes", "pipefail", "--done" })
  eq(c, 0, err)
  eq(
    out,
    "lib.nvim/shell\t#bash\tlearned\t[Bash-Handbuch](https://www.gnu.org/software/bash/manual/)\t"
      .. "Notiz: `set -euo pipefail` am Anfang."
  )
  local c3, _, err3 = run({ "learn", "notes", "--limit=1" })
  eq(c3, 0)
  has(err3, "1 of 2 hits shown")
  c, out = run({ "learn", "notes", "--kind=link", "--format=json" })
  eq(c, 0)
  eq(#vim.json.decode(out).items, 1)
  eq((run({ "learn", "notes", "--kind=video" })), 2)
  eq((run({ "learn", "notes", "--limit=x" })), 2)
end
