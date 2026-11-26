-- TESTS/tasks_learn_result_ask_spec.lua -- ticking off an exercise point in the editor asks for the result: a point
-- whose `Nachweis` has no `Ergebnis` is learned with a result (`LP-04`), so `ui.learn` asks for it (the prompt names the
-- Nachweis) and writes it in the same step as the state. A cancelled question changes nothing, an empty answer is
-- refused, a saved buffer goes through `paths.point` on disk, an unsaved one is changed in the buffer (the lines below
-- the note move), and under `{safety}` the reader is asked first whether the text was read.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local learn = require("tasks_nvim.ui.learn")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)
  local file = root .. "/lib.nvim/ROADMAP/paths/shell.md"
  local BODY = table.concat({
    "---",
    "title: Shell",
    "status: doing",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Üben: Verzeichnis anzeigen {#ls}",
    "  > **Aufgabe:** List the folder with `ls -l`.",
    "  > **Fertig, wenn:** you see the permissions.",
    "  > **Nachweis:** Paste the first line of the output.",
    "  > **Ergebnis:**",
    "- [ ] Lesen {#lesen}",
    "- [ ] Üben: schon bewiesen {#done}",
    "  > **Aufgabe:** Anything.",
    "  > **Nachweis:** Name it.",
    "  > **Ergebnis:** it is done",
    "- [ ] Netzteil {safety} {#netz}",
    "  - [ ] Üben: Messen {#messen}",
    "    > **Aufgabe:** Measure.",
    "    > **Nachweis:** The value.",
    "    > **Ergebnis:**",
    "",
  }, "\n")

  local real_input, real_select = vim.ui.input, vim.ui.select
  local asked
  local answer
  vim.ui.input = function(opts, cb)
    asked[#asked + 1] = opts.prompt
    cb(answer)
  end
  local function reset(body)
    H.write(file, body or BODY)
    vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
    asked = {}
    return vim.api.nvim_get_current_buf()
  end
  local function row_of(buf, key)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("{#" .. key .. "}", 1, true) then
        return i
      end
    end
  end
  local function tick(buf, key)
    local finished
    learn.set_point_asking(buf, row_of(buf, key), "learned", nil, function(n, e)
      finished = { node = n, err = e }
    end)
    return finished
  end

  -- ── a saved buffer: the result and the state in one write on disk ──
  local buf = reset()
  answer = "drwxr-xr-x 2 me me 4096 .  "
  local fin = tick(buf, "ls")
  eq(#asked, 1, "the result is asked for once")
  has(asked[1], "Paste the first line of the output", "the question names the Nachweis")
  eq(fin.err, nil, vim.inspect(fin))
  local disk = H.read(file)
  has(disk, "- [x] Üben: Verzeichnis anzeigen {#ls}")
  has(disk, "  > **Ergebnis:** drwxr-xr-x 2 me me 4096 .")
  has(disk, "- [ ] Lesen {#lesen}", "the next point is untouched")

  -- ── a cancelled question changes nothing ──
  buf = reset()
  answer = nil
  fin = tick(buf, "ls")
  eq(#asked, 1)
  eq(fin, { node = nil, err = nil }, "cancelled: neither a point nor an error")
  eq(H.read(file), BODY, "cancelled: the file is as it was")

  -- ── an empty answer is refused ──
  buf = reset()
  answer = "   "
  fin = tick(buf, "ls")
  has(fin.err, "learned needs a result")
  eq(H.read(file), BODY, "refused: the file is as it was")

  -- ── an unsaved buffer: the buffer changes, the lines below the note move, the file is not touched ──
  buf = reset()
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "- [ ] Zusatz {#extra}" })
  ok(vim.bo[buf].modified, "the buffer has unsaved changes")
  answer = "first line"
  fin = tick(buf, "ls")
  eq(fin.err, nil, vim.inspect(fin))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ls_row = row_of(buf, "ls")
  eq(lines[ls_row], "- [x] Üben: Verzeichnis anzeigen {#ls}")
  eq(lines[ls_row + 4], "  > **Ergebnis:** first line", "the result is on the Ergebnis line")
  eq(lines[ls_row + 5], "- [ ] Lesen {#lesen}", "the point below follows the note")
  eq(lines[#lines], "- [ ] Zusatz {#extra}", "the unsaved line is kept")
  eq(H.read(file), BODY, "the file on disk is not written")

  -- ── a point that already has its result is not asked ──
  buf = reset()
  answer = "never used"
  fin = tick(buf, "done")
  eq(#asked, 0, "a point with a result is ticked without a question")
  eq(fin.err, nil, vim.inspect(fin))
  has(H.read(file), "- [x] Üben: schon bewiesen {#done}")

  -- ── a point without an exercise block is not asked ──
  buf = reset()
  tick(buf, "lesen")
  eq(#asked, 0, "no question for a plain point")
  has(H.read(file), "- [x] Lesen {#lesen}")

  -- ── under {safety}: first "read?", then the result ──
  buf = reset()
  local order = {}
  vim.ui.select = function(_, _, cb)
    order[#order + 1] = "select"
    cb("Gelesen")
  end
  local real_in = vim.ui.input
  vim.ui.input = function(opts, cb)
    order[#order + 1] = "input"
    real_in(opts, cb)
  end
  answer = "4.7 V"
  fin = tick(buf, "messen")
  eq(order, { "select", "input" }, "the safety question comes before the result")
  eq(fin.err, nil, vim.inspect(fin))
  disk = H.read(file)
  has(disk, "- [x] Üben: Messen {#messen}")
  has(disk, "    > **Ergebnis:** 4.7 V")
  lacks(disk, "- [x] Netzteil", "the parent has no mark of its own")

  vim.ui.input, vim.ui.select = real_input, real_select
end
