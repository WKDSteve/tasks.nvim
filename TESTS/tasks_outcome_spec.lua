-- TESTS/tasks_outcome_spec.lua -- `outcome`: how a finished task ended (learned, seen, not-applicable) beside
-- `status: done`. The field (model), the writes (set, new, done with the required reason), the Backlog row, the
-- listing of finished tasks (`list --done`, `--outcome=`), the preview, the `check` hints and the next round of a
-- routine. A finish that names no outcome stays what it was.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local cli = require("tasks_nvim.cli")
  local done_flow = require("tasks_nvim.done_flow")
  local filter_opts = require("tasks_nvim.filter_opts")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local TODAY = F.TODAY or "2026-11-19"

  ---@param meta table[]
  ---@return Tasks.Task
  local function parse(meta)
    return model.parse_text(F.text(meta), {
      path = "/v/a/ROADMAP/tasks/t.md",
      area = "a",
      location = "roadmap",
    })
  end

  -- ── the words ─────────────────────────────────────────────────────────────
  for _, w in ipairs({ "learned", "seen", "not-applicable" }) do
    ok(model.is_outcome(w), w .. " is an outcome")
  end
  for _, w in ipairs({ "done", "Seen", "", "not_applicable" }) do
    ok(not model.is_outcome(w), "'" .. w .. "' is no outcome")
  end
  ok(not model.is_outcome(nil))

  -- ── model ─────────────────────────────────────────────────────────────────
  local seen = parse(F.meta("S", "open", { { "outcome", "seen" }, { "outcome_reason", "no Mac" } }))
  ok(seen.valid, vim.inspect(seen.errors))
  eq(seen.outcome, "seen")
  eq(seen.outcome_reason, "no Mac")
  local plain = parse(F.meta("P", "open"))
  eq(plain.outcome, nil, "no outcome: done as meant")
  local wrong = parse(F.meta("W", "open", { { "outcome", "maybe" } }))
  ok(not wrong.valid, "an unknown word is an error")
  eq(wrong.error_codes, { "unknown-outcome" })
  has(wrong.errors[1], "unknown outcome 'maybe'")

  -- ── set and new ───────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local function new(title, extra)
    return assert(
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = title }, extra or {}))
    )
  end
  local function find(id)
    return assert(scan.find(id, { root = root }))
  end

  local early = new("Note in advance")
  assert(mutate.set(early.id, { outcome = "not-applicable", outcome_reason = "no such device" }, o))
  eq(find(early.id).outcome, "not-applicable", "set outcome= on an open task is a note in advance")
  eq(find(early.id).outcome_reason, "no such device")
  has(select(2, mutate.set(early.id, { outcome = "maybe" }, o)), "unknown outcome 'maybe'")
  assert(mutate.set(early.id, { outcome = mutate.REMOVE }, o))
  eq(find(early.id).outcome, nil, "an empty value removes it")

  local made = new("Made seen", { outcome = "seen", outcome_reason = "later" })
  has(H.read(made.path), "outcome: seen\noutcome_reason: later\n")
  has(
    select(
      2,
      mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "X", outcome = "maybe" }))
    ),
    "unknown outcome 'maybe'"
  )

  -- ── done: the regression first, then the outcomes ─────────────────────────
  local function readme()
    return H.read(root .. "/lib.nvim/Backlog/README.md")
  end
  local before = new("Plain finish")
  local plain_done = assert(mutate.done(before.id, o))
  local plain_text = H.read(plain_done.to)
  lacks(plain_text, "outcome", "a finish without an outcome writes none")
  eq(plain_done.outcome, nil)
  has(readme(), "Plain finish (" .. TODAY .. ") |", "the row is what it always was")

  local looked = new("Looked at")
  local _, need = mutate.done(looked.id, vim.tbl_extend("force", o, { outcome = "seen" }))
  has(need, "outcome seen needs a reason")
  ok(scan.find(looked.id, { root = root }), "a refused finish leaves the task open")
  local _, need_na = mutate.done(
    looked.id,
    vim.tbl_extend("force", o, { outcome = "not-applicable", outcome_reason = "  " })
  )
  has(need_na, "outcome not-applicable needs a reason", "a blank reason is no reason")
  local _, bad = mutate.done(looked.id, vim.tbl_extend("force", o, { outcome = "maybe" }))
  has(bad, "unknown outcome 'maybe'")
  local _, lone = mutate.done(looked.id, vim.tbl_extend("force", o, { outcome_reason = "why" }))
  has(lone, "a reason belongs to an outcome")

  local pv = assert(
    mutate.done_preview(
      looked.id,
      vim.tbl_extend("force", o, { outcome = "seen", outcome_reason = "no Mac" })
    )
  )
  eq(pv.outcome, "seen", "the preview names the outcome")
  eq(pv.outcome_reason, "no Mac")
  has(pv.readme_row, "(" .. TODAY .. ", seen: no Mac) |")

  local res = assert(
    mutate.done(
      looked.id,
      vim.tbl_extend("force", o, { outcome = "seen", outcome_reason = "no Mac" })
    )
  )
  eq(res.outcome, "seen")
  eq(res.outcome_reason, "no Mac")
  local text = H.read(res.to)
  has(text, "status: done\n")
  has(text, "outcome: seen\n")
  has(text, "outcome_reason: no Mac\n")
  has(readme(), "Looked at (" .. TODAY .. ", seen: no Mac) |", "the Backlog row names how it ended")

  local learned = new("Learned it")
  local lres = assert(mutate.done(learned.id, vim.tbl_extend("force", o, { outcome = "learned" })))
  has(H.read(lres.to), "outcome: learned\n", "learned needs no reason")
  has(readme(), "Learned it (" .. TODAY .. ", learned) |")

  -- the reason the task already has counts; a reason alone completes the task's own outcome
  local noted = assert(mutate.done(made.id, vim.tbl_extend("force", o, { outcome = "seen" })))
  has(H.read(noted.to), "outcome_reason: later\n")
  local pre = new("Pre-noted", { outcome = "not-applicable" })
  local pres =
    assert(mutate.done(pre.id, vim.tbl_extend("force", o, { outcome_reason = "obsolete" })))
  eq(pres.outcome, "not-applicable")
  has(H.read(pres.to), "outcome_reason: obsolete\n")

  -- ── list --done and the filter ────────────────────────────────────────────
  local function run(argv)
    local out, err = {}, {}
    local args = vim.deepcopy(argv)
    vim.list_extend(args, { "--vault=" .. root, "--today=" .. TODAY })
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local all = run({ "list", "lib.nvim", "--done" })
  eq(all.code, 0, all.err)
  has(all.out, "lib.nvim/looked-at\tdone:seen\t")
  has(all.out, "lib.nvim/plain-finish\tdone\t", "a task without an outcome lists as it always did")
  local only = run({ "list", "lib.nvim", "--done", "--outcome=seen", "--format=ids" })
  eq(only.code, 0, only.err)
  local seen_ids = vim.split(vim.trim(only.out), "\n")
  table.sort(seen_ids)
  eq(seen_ids, { "lib.nvim/looked-at", "lib.nvim/made-seen" })
  local none = run({ "list", "lib.nvim", "--done", "--outcome=none", "--format=ids" })
  eq(vim.trim(none.out), "lib.nvim/plain-finish")
  eq(select(2, filter_opts.parse({ outcome = "maybe" })), "unknown outcome in --outcome: maybe")

  -- the command line: --outcome and --reason
  local cmd = new("By the command line")
  local refused = run({ "done", cmd.id, "--outcome=not-applicable" })
  eq(refused.code, 1)
  has(refused.err, "needs a reason")
  local cdone = run({ "done", cmd.id, "--outcome=not-applicable", "--reason=out of scope" })
  eq(cdone.code, 0, cdone.err)
  local cfin = assert(scan.find_done(cmd.id, { root = root }))
  eq(cfin.outcome, "not-applicable")
  eq(cfin.outcome_reason, "out of scope")

  -- ── check: hints only ─────────────────────────────────────────────────────
  local croot = F.vault(H)
  F.task(H, croot, "lib.nvim", "ahead", F.meta("Ahead", "open", { { "outcome", "learned" } }))
  F.task(H, croot, "lib.nvim", "bare", F.meta("Bare", "open", { { "outcome", "seen" } }))
  H.write(
    croot .. "/lib.nvim/Backlog/TASKS/2026-11-01_old.md",
    F.text(F.meta("Old", "done", { { "kind", "task" }, { "outcome", "not-applicable" } }))
  )
  local r = assert(check.run({ root = croot, area = "lib.nvim", today = TODAY }))
  local codes = {}
  for _, h in ipairs(r.hints) do
    if h.code:find("^outcome") then
      codes[#codes + 1] = h.code .. ":" .. h.id
      eq(h.severity, "info")
    end
  end
  table.sort(codes)
  eq(codes, {
    "outcome-on-open-task:lib.nvim/ahead",
    "outcome-on-open-task:lib.nvim/bare",
    "outcome-without-reason:lib.nvim/bare",
    "outcome-without-reason:lib.nvim/old",
  })
  for _, f in ipairs(r.findings) do
    ok(not f.code:find("^outcome"), "an outcome is never a warning: " .. f.code)
  end

  -- ── a routine's next round starts without the outcome ─────────────────────
  local rroot = F.vault(H)
  F.task(
    H,
    rroot,
    "lib.nvim",
    "sweep",
    F.meta(
      "Sweep",
      "open",
      { { "due", "2026-11-01" }, { "repeat", "8w" }, { "created", "2026-09-01" } }
    )
  )
  local flow = assert(done_flow.run("lib.nvim/sweep", {
    root = rroot,
    today = TODAY,
    index = false,
    pick_next = false,
    outcome = "seen",
    outcome_reason = "skipped this round",
  }))
  local fin = assert(scan.find_done("lib.nvim/sweep", { root = rroot }))
  eq(fin.outcome, "seen", "the finished round keeps how it ended")
  local nxt = assert(scan.find(flow.next_round.id, { root = rroot }))
  eq(nxt.outcome, nil, "the next round has not ended yet")
  eq(nxt.outcome_reason, nil)

  -- ── the editor: `:Tasks done <id> outcome=... reason=... remind=... --yes` hands every word to the finish ──────
  local ui_cmd = require("tasks_nvim.ui.cmd")
  local eroot = F.vault(H)
  F.task(H, eroot, "lib.nvim", "by-editor", F.meta("By editor", "open"))
  require("tasks_nvim.vault").set_root(eroot)
  local real_notify = vim.notify
  vim.notify = function() end
  ui_cmd.task_done({
    rest = {},
    args = { id = "lib.nvim/by-editor" },
    kv = { outcome = "seen", reason = "no time", remind = "+7d" },
    flags = { yes = true },
  })
  vim.notify = real_notify
  local efin = assert(scan.find_done("lib.nvim/by-editor", { root = eroot }))
  eq(efin.outcome, "seen", ":Tasks done passes outcome=")
  eq(efin.outcome_reason, "no time")
  ok(efin.remind ~= nil, ":Tasks done passes remind= (it was dropped before)")
end
