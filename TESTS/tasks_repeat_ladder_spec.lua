-- TESTS/tasks_repeat_ladder_spec.lua -- routines as a ladder and routines that start after something is finished:
-- `repeat: 1w,4w,12w` (each round takes the next interval, `repeat_step` counts it, the last round ends the routine as
-- `--last` does) and `repeat_after: <id>|<path>#<key>` (no `repeat-without-due` while it waits; the finish of the task,
-- the point or the path writes due = that day + the first interval). Model, frontmatter, new/set, done flow, paths,
-- check, the write door and the CLI.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local cli = require("tasks_nvim.cli")
  local done_flow = require("tasks_nvim.done_flow")
  local fsio = require("tasks_nvim.fsio")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local ops = require("tasks_nvim.ops")
  local paths = require("tasks_nvim.paths")
  local scan = require("tasks_nvim.scan")

  -- ── the ladder in the model ────────────────────────────────────────────────
  eq(model.parse_repeat_steps("1w,4w,12w"), {
    { n = 1, unit = "w" },
    { n = 4, unit = "w" },
    { n = 12, unit = "w" },
  })
  eq(
    model.parse_repeat_steps("8w"),
    { { n = 8, unit = "w" } },
    "one interval is a routine for good"
  )
  for _, bad in ipairs({ "1w,", ",1w", "1w,,4w", "1w, 4w", "1w,0d", "1w,4x", "", 3 }) do
    ok(not model.is_repeat_steps(bad), "no ladder: " .. tostring(bad))
  end
  ok(
    not model.is_repeat_steps(("1w,"):rep(model.REPEAT_STEPS_MAX) .. "1w"),
    "at most REPEAT_STEPS_MAX rounds"
  )
  ok(not model.is_repeat("1w,4w"), "a meeting's series takes one interval only")
  has(model.repeat_steps_error("x"), "1w,4w,12w")

  local L = { repeat_every = "1w,4w,12w" }
  eq(
    { model.next_round_due(L, "2026-11-10", "2026-11-10") },
    { "2026-12-08", 2 },
    "the first round finished: the second interval (4w) from the finish"
  )
  eq({
    model.next_round_due(
      vim.tbl_extend("force", L, { repeat_step = 2 }),
      "2026-12-08",
      "2026-12-08"
    ),
  }, { "2027-03-02", 3 }, "the second round finished: 12w")
  eq(
    model.next_round_due(
      vim.tbl_extend("force", L, { repeat_step = 3 }),
      "2027-03-02",
      "2027-03-02"
    ),
    nil,
    "after the last round there is none"
  )
  eq({
    model.next_round_due(
      vim.tbl_extend("force", L, { repeat_from = "due", due = "2026-11-01" }),
      "2026-11-10",
      "2026-11-10"
    ),
  }, { "2026-11-29", 2 }, "from the due date: once by the next interval")
  eq(
    { model.next_round_due({ repeat_every = "8w" }, "2026-11-10", "2026-11-10") },
    { "2027-01-05" },
    "a routine of one interval answers no step"
  )
  ok(not model.is_last_round(L))
  ok(model.is_last_round(vim.tbl_extend("force", L, { repeat_step = 3 })))
  ok(not model.is_last_round({ repeat_every = "8w", repeat_step = 1 }), "one interval never ends")
  eq(model.first_round_due(L, "2026-11-10"), "2026-11-17")
  eq(model.to_repeat_step("2"), 2)
  eq(model.to_repeat_step(3), 3)
  for _, bad in ipairs({ "0", "02", "x", 1.5, 0, model.REPEAT_STEPS_MAX + 1 }) do
    eq(model.to_repeat_step(bad), nil, "no round: " .. tostring(bad))
  end
  for _, good in ipairs({ "lib.nvim/check", "Learning/neoload#korrelation", "a/b#key_1-2" }) do
    ok(model.is_repeat_after(good), "a reference: " .. good)
  end
  for _, bad in ipairs({ "check", "a/b/c", "../x/y", "a/..", "a/b#", "a/b#k y", "a/b#k#l", 3 }) do
    ok(not model.is_repeat_after(bad), "no reference: " .. tostring(bad))
  end

  -- ── the frontmatter ────────────────────────────────────────────────────────
  local function parse(front)
    return model.parse_text(
      "---\ntitle: A\nstatus: open\n" .. front .. "created: 2026-01-01\n---\n\nBody.\n",
      { path = "/v/a/ROADMAP/tasks/a.md", area = "a" }
    )
  end
  local function codes(task)
    local out = {}
    for _, h in ipairs(task.hints) do
      out[#out + 1] = h.code
    end
    for _, c in ipairs(task.error_codes) do
      out[#out + 1] = c
    end
    return out
  end
  local waiting = parse("repeat: 1w,4w,12w\nrepeat_after: Learning/neoload#korrelation\n")
  eq(waiting.repeat_every, "1w,4w,12w", "a ladder is one text, not a list")
  eq(waiting.repeat_after, "Learning/neoload#korrelation", "a # after a word is no comment")
  eq(codes(waiting), {}, "a routine that waits for its start has no repeat-without-due")
  eq(codes(parse("repeat: 1w,4w,12w\n")), { "repeat-without-due" })
  local step2 = parse("due: 2026-12-08\nrepeat: 1w,4w,12w\nrepeat_step: 2\n")
  eq(step2.repeat_step, 2)
  eq(codes(step2), {})
  eq(codes(parse("due: 2026-12-08\nrepeat: 1w,4w,12w\nrepeat_step: 4\n")), { "bad-repeat" })
  eq(codes(parse("due: 2026-12-08\nrepeat: 1w,4w\nrepeat_step: 0\n")), { "bad-repeat" })
  eq(
    codes(parse("due: 2026-12-08\nrepeat: 8w\nrepeat_step: 2\n")),
    { "repeat-step-without-ladder" }
  )
  eq(codes(parse("repeat_after: a/b\n")), { "repeat-after-without-repeat" })
  eq(codes(parse("repeat: 8w\nrepeat_after: nope\n")), { "repeat-without-due", "bad-repeat" })
  eq(codes(parse("due: 2026-12-08\nrepeat: 1w,,4w\n")), { "bad-repeat" })

  -- ── new and set ────────────────────────────────────────────────────────────
  local root = F.vault(H)
  local A = "lib.nvim"
  local TODAY = "2026-11-10"
  local o = { root = root, today = TODAY, index = false }
  local function with(extra)
    return vim.tbl_extend("force", o, extra)
  end
  local trigger = assert(mutate.new(A, with({ title = "Selbstcheck" })))
  local made = assert(mutate.new(
    A,
    with({
      title = "Selbstcheck wiederholen",
      repeat_every = "1w,4w,12w",
      repeat_after = trigger.id,
    })
  ))
  local text = H.read(made.path)
  has(text, "repeat: 1w,4w,12w")
  has(text, "repeat_after: " .. trigger.id)
  ok(not text:find("\ndue:", 1, true), "no due date until it starts")
  has(
    select(2, mutate.new(A, with({ title = "X", repeat_after = trigger.id }))),
    "repeat_after needs repeat"
  )
  has(
    select(2, mutate.new(A, with({ title = "Y", repeat_every = "8w", repeat_after = "nope" }))),
    "is no id"
  )
  has(select(2, mutate.new(A, with({ title = "Z", repeat_every = "1w,soon" }))), "1w,4w,12w")
  local other = assert(mutate.new(A, with({ title = "Other", due = "2026-12-01" })))
  assert(mutate.set(other.id, { ["repeat"] = "2w,6w", repeat_step = "2" }, o))
  local other_text = H.read(other.path)
  has(other_text, "repeat: 2w,6w")
  has(other_text, "repeat_step: 2")
  has(select(2, mutate.set(other.id, { repeat_step = "x" }, o)), "repeat_step must be")
  has(select(2, mutate.set(other.id, { repeat_after = "a" }, o)), "is no id")
  assert(mutate.set(other.id, { repeat_after = "lib.nvim/whatever#k" }, o))
  has(H.read(other.path), "repeat_after: lib.nvim/whatever#k")

  local flow_opts = { root = root, today = TODAY, date = TODAY, index = false, pick_next = false }
  local function codes_of(id)
    local res = check.run({ root = root, today = TODAY })
    local out = {}
    for _, f in ipairs(res.findings) do
      if f.id == id then
        out[#out + 1] = f.code
      end
    end
    table.sort(out)
    return out
  end
  eq(codes_of(made.id), {}, "waiting for an open task: nothing to say")
  eq(codes_of(other.id), {}, "a routine with a due date has started: its reference is history")

  -- ── the start after a task ─────────────────────────────────────────────────
  local flow = assert(done_flow.run(trigger.id, flow_opts))
  eq(flow.routines_started, { { id = made.id, due = "2026-11-17", after = trigger.id } })
  local started = assert(scan.find(made.id, { root = root }))
  eq({ started.due, started.start, started.remind }, { "2026-11-17", "2026-11-17", "2026-11-17" })
  eq(started.repeat_after, trigger.id, "the reference stays in the first round")
  eq(codes_of(made.id), {}, "started: nothing to say")

  -- ── the ladder in the done flow ────────────────────────────────────────────
  flow = assert(done_flow.run(made.id, vim.tbl_extend("force", flow_opts, { date = "2026-11-17" })))
  local r2 = flow.next_round
  eq(r2.due, "2026-12-15", "the second round: 4w from the finish")
  eq(r2.id, A .. "/selbstcheck-wiederholen-2026-12-15")
  local r2_task = assert(scan.find(r2.id, { root = root }))
  eq(r2_task.repeat_step, 2)
  eq(r2_task.repeat_after, nil, "the next round no longer waits for anything")
  eq(r2_task.repeat_every, "1w,4w,12w")
  eq(flow.routines_started, {})

  flow = assert(done_flow.run(r2.id, vim.tbl_extend("force", flow_opts, { date = "2026-12-15" })))
  local r3 = flow.next_round
  eq(r3.due, "2027-03-09", "the third round: 12w")
  eq(assert(scan.find(r3.id, { root = root })).repeat_step, 3)

  local pv = assert(done_flow.preview(r3.id, flow_opts))
  eq(pv.next_round, nil, "the last round has no next one")
  eq(pv.ends_routine, true)
  flow = assert(done_flow.run(r3.id, vim.tbl_extend("force", flow_opts, { date = "2027-03-09" })))
  eq(flow.next_round, nil)
  eq(flow.routine_ended, true, "the last round ends the routine as --last does")
  eq(flow.notes, {})
  ok(scan.find_done(r3.id, { root = root }), "the last round is in the Backlog")
  for _, t in ipairs(assert(scan.open_tasks({ root = root }))) do
    ok(not t.id:find("selbstcheck-wiederholen", 1, true), "no round is open any more: " .. t.id)
  end
  local rounds =
    assert(done_flow.rounds(assert(scan.find_done(r3.id, { root = root })), { root = root }))
  eq(#rounds, 2, "the two earlier rounds are its rounds (the last one is the task itself)")

  -- ── the start after a point of a path, and after the path ──────────────────
  local path_file = root .. "/" .. A .. "/ROADMAP/paths/app-architektur.md"
  H.write(
    path_file,
    table.concat({
      "---",
      "title: App-Architektur",
      "status: doing",
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [ ] Stufe 0 {#s0}",
      "  - [ ] Bundle lesen {#bundle}",
      "  - [ ] Hub lesen {#hub}",
      "- [ ] Selbstcheck {#selbstcheck}",
      "- [ ] Altes {#alt}",
      "",
    }, "\n")
  )
  local P = A .. "/app-architektur"
  local function routine(title, after)
    return assert(
      mutate.new(A, with({ title = title, repeat_every = "1w,4w,12w", repeat_after = after }))
    )
  end
  local on_point = routine("Nach dem Selbstcheck", P .. "#selbstcheck")
  local on_stage = routine("Nach Stufe 0", P .. "#s0")
  local on_dropped = routine("Nach dem Alten", P .. "#alt")
  local on_path = routine("Nach dem Pfad", P)
  local on_nothing = routine("Nach nichts", P .. "#gibtsnicht")
  eq(codes_of(on_nothing.id), { "repeat-after-unknown" })
  eq(codes_of(on_point.id), {})

  local po = { root = root, today = "2026-11-20", index = false }
  local res = assert(paths.point(P, "selbstcheck", "learned", nil, po))
  eq(
    res.routines_started,
    { { id = on_point.id, due = "2026-11-27", after = P .. "#selbstcheck" } }
  )
  eq(assert(scan.find(on_point.id, { root = root })).due, "2026-11-27")
  -- a stage starts when its last leaf is closed
  res = assert(paths.point(P, "bundle", "learned", nil, po))
  eq(res.routines_started, {}, "one leaf of the stage is still open")
  res = assert(paths.point(P, "hub", "seen", "nur überflogen", po))
  eq(res.routines_started, { { id = on_stage.id, due = "2026-11-27", after = P .. "#s0" } })
  -- a point dropped in full starts nothing
  res = assert(paths.point(P, "alt", "dropped", "nicht nötig", po))
  eq(res.routines_started, {})
  eq(assert(scan.find(on_dropped.id, { root = root })).due, nil)
  -- a dry run writes nothing
  eq(
    paths.point(P, "alt", "learned", nil, vim.tbl_extend("force", po, { dry_run = true })).routines_started,
    nil
  )
  -- the whole path, when it is closed
  local closed = assert(
    paths.close(P, { root = root, today = "2026-11-24", date = "2026-11-24", index = false })
  )
  eq(closed.routines_started, { { id = on_path.id, due = "2026-12-01", after = P } })
  eq(assert(scan.find(on_path.id, { root = root })).due, "2026-12-01")
  -- a point of the closed path: read from the Backlog
  eq(codes_of(on_dropped.id), {}, "dropped in full: still waiting, nothing missed")

  -- ── check: a start that was missed ─────────────────────────────────────────
  F.task(
    H,
    root,
    A,
    "spaet",
    F.meta("Spät angelegt", "open", {
      { "repeat", "1w,4w,12w" },
      { "repeat_after", trigger.id },
      { "created", TODAY },
    }),
    "\nText.\n"
  )
  eq(codes_of(A .. "/spaet"), { "repeat-after-missed" })
  local missed
  for _, f in ipairs(check.run({ root = root, today = TODAY }).findings) do
    if f.code == "repeat-after-missed" then
      missed = f.message
    end
  end
  has(missed, "set due=2026-11-17", "the message names the due date it would have")

  -- ── the write door and the command line ────────────────────────────────────
  local t2 = assert(mutate.new(A, with({ title = "Zweiter Auslöser" })))
  local waits = routine("Nach dem zweiten", t2.id)
  local etag = fsio.etag(H.read(t2.path))
  local doc = assert(ops.run({
    ops = { { op = "done", id = t2.id, confirm = mutate.confirm_token(t2.id, etag) } },
  }, { root = root, today = TODAY }))
  local e = doc.results[1]
  eq(e.ok, true, vim.inspect(e))
  eq(#e.routines_started, 1)
  eq(e.routines_started[1].id, waits.id)
  eq(e.routines_started[1].due, "2026-11-17")
  ok(vim.tbl_contains(e.changed_ids, waits.id), "the started routine is a changed document")

  local t3 = assert(mutate.new(A, with({ title = "Dritter Auslöser" })))
  local waits3 = routine("Nach dem dritten", t3.id)
  local out, err = {}, {}
  local code = cli.run({ "done", t3.id, "--vault=" .. root, "--today=" .. TODAY, "--no-next" }, {
    out = function(t)
      out[#out + 1] = t
    end,
    err = function(t)
      err[#err + 1] = t
    end,
  })
  eq(code, 0, table.concat(err, "\n"))
  has(table.concat(out, "\n"), "routine-started\t" .. waits3.id .. "\t2026-11-17\tafter " .. t3.id)

  -- `new --repeat-after` on the command line
  out, err = {}, {}
  code = cli.run({
    "new",
    A,
    "Per CLI",
    "--repeat=1w,4w,12w",
    "--repeat-after=" .. t3.id,
    "--vault=" .. root,
    "--today=" .. TODAY,
  }, {
    out = function(t)
      out[#out + 1] = t
    end,
    err = function(t)
      err[#err + 1] = t
    end,
  })
  eq(code, 0, table.concat(err, "\n"))
  local cli_task = assert(scan.find(A .. "/per-cli", { root = root }))
  eq({ cli_task.repeat_every, cli_task.repeat_after }, { "1w,4w,12w", t3.id })

  -- ── the editor: a point set in `:Tasks learn` says that a routine starts ───
  require("tasks_nvim.vault").set_root(root)
  local learn = require("tasks_nvim.ui.learn")
  local editor_path = root .. "/" .. A .. "/ROADMAP/paths/editor-pfad.md"
  H.write(
    editor_path,
    "---\ntitle: Editor\nstatus: doing\n---\n\n## Lernpunkte\n\n- [ ] Eins {#eins}\n- [ ] Zwei {#zwei}\n"
  )
  local in_editor = routine("Nach Eins im Editor", A .. "/editor-pfad#eins")
  local told = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    told[#told + 1] = tostring(msg)
  end
  vim.cmd("silent edit! " .. vim.fn.fnameescape(editor_path))
  local ebuf = vim.api.nvim_get_current_buf()
  local set_ok, set_err = learn.set_point(ebuf, 8, "learned")
  vim.notify = real_notify
  ok(set_ok, tostring(set_err))
  has(table.concat(told, "\n"), "routine " .. in_editor.id .. " starts: due ")
  vim.cmd("silent bwipeout! " .. ebuf)
end
