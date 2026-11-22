-- TESTS/tasks_path_ack_spec.lua -- closing a learning point under `{safety}` needs the reader's ack on every write
-- door: the CLI `tasks point` (`--ack`), the operation `node_set` (its inverse carries the ack), the editor
-- (`ui.learn`: the question shows the text), and `done` of a task promoted from such a point (`--ack`, else the point
-- stays open and the finish says so).
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local ops_mod = require("tasks_nvim.ops")
  local promote = require("tasks_nvim.promote")
  local done_flow = require("tasks_nvim.done_flow")
  local learn = require("tasks_nvim.ui.learn")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)
  local A, TODAY = "lib.nvim", F.TODAY
  local ID = A .. "/strom"
  local file = root .. "/" .. A .. "/ROADMAP/paths/strom.md"
  local BODY = table.concat({
    "---",
    "title: Strom",
    "status: doing",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Netzteil {safety} {#netz}",
    "  - [ ] Öffnen {#oeffnen}",
    "  - [ ] Messen {#messen}",
    "- [ ] Lesen {#lesen}",
    "",
  }, "\n")
  H.write(file, BODY)

  local function run(argv)
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

  -- ── tasks point ──
  local code, _, err = run({ "point", ID, "oeffnen", "--state=learned" })
  eq(code, 2, "a point under {safety} needs --ack")
  has(err, "{safety}")
  has(err, "Netzteil")
  lacks(H.read(file), "- [x] Öffnen")
  local out
  code, out, err = run({ "point", ID, "oeffnen", "--state=learned", "--ack" })
  eq(code, 0, err)
  has(out, "changed\t" .. ID .. "\t#oeffnen\tlearned")
  has(H.read(file), "- [x] Öffnen {#oeffnen}")
  code, _, err = run({ "point", ID, "lesen", "--state=learned" })
  eq(code, 0, "a point outside {safety} needs no ack: " .. err)
  code = run({ "point", ID, "messen", "--state=seen" })
  eq(code, 2, "seen is a close too")
  code = run({ "point", ID, "messen", "--state=open" })
  eq(code, 0, "opening needs no ack")
  code, _, err = run({ "point", ID })
  eq(code, 2)
  has(err, "usage: point")
  code = run({ "point", ID, "nope", "--state=open" })
  ok(code ~= 0, "an unknown point is an error")

  -- ── the inverse of reopening a point that was closed under {safety} ──
  local function node_set(op)
    op.op, op.id = "node_set", ID
    local doc = assert(ops_mod.run({ ops = { op } }, { root = root, today = TODAY }))
    return doc.results[1]
  end
  local re = node_set({ point = "oeffnen", state = "open" })
  eq(re.ok, true, vim.inspect(re))
  eq(re.inverse.state, "learned")
  eq(re.inverse.ack, true, "giving the close back was read once")
  local back = node_set(re.inverse)
  eq(back.ok, true, "the inverse runs: " .. vim.inspect(back))
  has(H.read(file), "- [x] Öffnen {#oeffnen}")
  local plain = node_set({ point = "lesen", state = "open" })
  eq(plain.inverse.ack, nil, "a point outside {safety} has no ack in its inverse")

  -- ── the editor ──
  vim.cmd("silent edit " .. vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  local function row_of(key)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("{#" .. key .. "}", 1, true) then
        return i
      end
    end
  end
  local row = row_of("messen")
  eq(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1], "  - [ ] Messen {#messen}")
  local _, serr = learn.set_point(buf, row, "learned")
  has(serr, "{safety}", "set_point refuses without the ack")
  local real_select = vim.ui.select
  local asked, choice = {}, "Abbrechen"
  vim.ui.select = function(items, opts, cb)
    asked[#asked + 1] = { items = items, prompt = opts.prompt }
    cb(choice)
  end
  local finished
  learn.set_point_asking(buf, row, "learned", nil, function(n, e)
    finished = { n, e }
  end)
  eq(#asked, 1)
  has(asked[1].prompt, "Netzteil", "the question shows the text of the mark")
  eq(finished, { nil, nil }, "cancelled: nothing written")
  lacks(H.read(file), "- [x] Messen")
  choice = "Gelesen"
  learn.set_point_asking(buf, row, "learned", nil, function(n, e)
    finished = { n, e }
  end)
  eq(finished[2], nil, vim.inspect(finished))
  has(H.read(file), "- [x] Messen {#messen}")
  -- a point outside the mark is not asked
  asked = {}
  learn.set_point_asking(buf, row_of("lesen"), "learned", nil, function() end)
  eq(#asked, 0, "no question outside {safety}")
  vim.ui.select = real_select

  -- ── done of a promoted task ──
  H.write(file, BODY)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local task = assert(promote.promote(ID, "oeffnen", o))
  local flow = assert(done_flow.run(task.id, vim.tbl_extend("force", o, { pick_next = false })))
  ok(flow.point and flow.point.held, "the point was held: " .. vim.inspect(flow.point))
  eq(flow.point.changed, false)
  eq(flow.point.state, "open")
  has(table.concat(flow.notes, "\n"), "stays open")
  has(table.concat(flow.notes, "\n"), "{safety}")
  lacks(H.read(file), "- [x] Öffnen")
  -- with the ack the point closes (take the task back first: a finished task cannot be finished again)
  require("tasks_nvim.mutate").reopen(task.id, o)
  local flow2 =
    assert(done_flow.run(task.id, vim.tbl_extend("force", o, { pick_next = false, ack = true })))
  eq(flow2.point.held, nil)
  eq(flow2.point.state, "learned")
  has(H.read(file), "- [x] Öffnen")
  -- a task promoted from a point outside the mark finishes as before
  local t2 = assert(promote.promote(ID, "lesen", o))
  local f3 = assert(done_flow.run(t2.id, vim.tbl_extend("force", o, { pick_next = false })))
  eq(f3.point.held, nil)
  eq(f3.point.state, "learned")

  -- the door: `done` takes ack
  H.write(file, BODY)
  local t3 = assert(promote.promote(ID, "messen", o))
  local pv = assert(
    require("tasks_nvim.done_flow").preview(t3.id, { root = root, today = TODAY }),
    "preview"
  )
  local res = assert(ops_mod.run({
    ops = { { op = "done", id = t3.id, confirm = pv.confirm } },
  }, { root = root, today = TODAY }))
  eq(res.results[1].ok, true, vim.inspect(res.results[1]))
  eq(res.results[1].point.held and true or false, true, "the entry says the point was held")
end
