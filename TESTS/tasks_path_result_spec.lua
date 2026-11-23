-- TESTS/tasks_path_result_spec.lua -- the `Ergebnis` of an exercise block through the write doors: the operation
-- `node_set` with `result` (one call writes the proof and ticks the point; a point with a `Nachweis` is refused
-- `learned` without one; `note` and `result` not together; the inverse gives the whole note back) and the command
-- `tasks point --result=`.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local cli = require("tasks_nvim.cli")
  local ops_mod = require("tasks_nvim.ops")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)
  local A, TODAY = "lib.nvim", F.TODAY
  local ID = A .. "/cli-uebung"
  local file = root .. "/" .. A .. "/ROADMAP/paths/cli-uebung.md"
  local BODY = table.concat({
    "---",
    "title: CLI Übung",
    "status: doing",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Üben: Verzeichnis anzeigen {#u1}",
    "  > **Aufgabe:** Lege drei Dateien an.",
    "  > **Fertig, wenn:** du es erklären kannst.",
    "  > **Nachweis:** Ausgabe einfügen.",
    "  > **Ergebnis:**",
    "- [ ] Üben: Pfad prüfen {#u2}",
    "- [ ] Lesen {#lesen}",
    "",
  }, "\n")
  H.write(file, BODY)

  local function run(list)
    local doc, err = ops_mod.run({ ops = list }, { root = root, today = TODAY })
    assert(doc, vim.inspect(err))
    return doc.results[1]
  end
  local function cli_run(argv)
    local out, err = {}, {}
    vim.list_extend(argv, { "--vault=" .. root, "--today=" .. TODAY })
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end

  local hello_text = api.call("hello", { params = {} }, { root = root, today = TODAY })
  local hello = vim.json.decode(hello_text)
  ok(vim.tbl_contains(hello.capabilities, "node_result"), "node_result")

  -- ── the operation ──
  local refused = run({ { op = "node_set", id = ID, point = "u1", state = "learned" } })
  eq(refused.ok, false)
  eq(refused.error.code, "invalid_argument")
  has(refused.error.message, "needs a result")
  has(H.read(file), "- [ ] Üben: Verzeichnis anzeigen", "a refused tick writes nothing")

  local both = run({ { op = "node_set", id = ID, point = "u1", note = "x", result = "y" } })
  eq(both.ok, false)
  has(both.error.message, "note or result")
  local empty = run({ { op = "node_set", id = ID, point = "u1" } })
  has(empty.error.message, "a state, a note, a result or xp")
  local ctl = run({ { op = "node_set", id = ID, point = "u1", result = "a\rb" } })
  eq(ctl.ok, false, "a carriage return is a control character")

  local done = run({
    { op = "node_set", id = ID, point = "u1", state = "learned", result = "ls -lh: ok" },
  })
  eq(done.ok, true, vim.inspect(done))
  eq(done.node.state, "learned")
  local disk = H.read(file)
  has(disk, "- [x] Üben: Verzeichnis anzeigen {#u1}")
  has(disk, "  > **Ergebnis:** ls -lh: ok")
  has(disk, "  > **Aufgabe:** Lege drei Dateien an.", "the other parts stay")

  -- the inverse gives the whole note and the state back
  eq(done.inverse.op, "node_set")
  has(done.inverse.note, "**Ergebnis:**", "the note as it was")
  lacks(done.inverse.note, "ls -lh: ok")
  local back = run({ done.inverse })
  eq(back.ok, true, vim.inspect(back))
  disk = H.read(file)
  has(disk, "- [ ] Üben: Verzeichnis anzeigen {#u1}")
  lacks(disk, "ls -lh: ok")

  local plain = run({ { op = "node_set", id = ID, point = "u2", result = "x" } })
  eq(plain.ok, false)
  has(plain.error.message, "no exercise block")
  local ticked = run({ { op = "node_set", id = ID, point = "u2", state = "learned" } })
  eq(ticked.ok, true, "a point without a block ticks as before")

  -- ── the command ──
  local code, _, err = cli_run({ "point", ID, "u1", "--state=learned" })
  eq(code, 2, err)
  has(err, "needs a result")
  code, _, err = cli_run({ "point", ID, "u1" })
  eq(code, 2)
  has(err, "usage: point")
  code, _, err = cli_run({ "point", ID, "u1", "--state=learned", "--result=erledigt per CLI" })
  eq(code, 0, err)
  has(H.read(file), "  > **Ergebnis:** erledigt per CLI")
  has(H.read(file), "- [x] Üben: Verzeichnis anzeigen {#u1}")
  code = cli_run({ "point", ID, "lesen", "--result=x" })
  eq(code, 2, "a reading point has no block to write into")
end
