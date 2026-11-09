-- TESTS/tasks_claim_spec.lua -- claims: a task reserved for the time somebody works on it (`tasks_nvim.claims`): the
-- time and name rules, `claim` / `unclaim`, the guard of every write path, `next`, `check`, the contract and the ops
-- door, the CLI, and two processes that claim the same task at once (exactly one wins).

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local claims = require("tasks_nvim.claims")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local next_pick = require("tasks_nvim.next_pick")

  -- ── time ───────────────────────────────────────────────────────────────────
  eq(claims.parse_time("1970-01-01T00:00:00Z"), 0)
  eq(claims.parse_time("2026-11-07T12:00:00Z"), 1794052800)
  eq(claims.parse_time("2026-11-07 12:00:00"), nil)
  eq(claims.add_seconds("2026-11-07T23:30:00Z", 3600), "2026-11-08T00:30:00Z", "over midnight")
  eq(claims.add_seconds("2026-12-31T23:59:59Z", 1), "2027-01-01T00:00:00Z", "over the year")
  eq(claims.add_seconds("2024-02-28T12:00:00Z", 86400), "2024-02-29T12:00:00Z", "a leap day")
  eq(claims.parse_duration("90m"), 5400)
  eq(claims.parse_duration("2h"), 7200)
  eq(claims.parse_duration("45"), 45)
  eq(select(1, claims.parse_duration("1d")), 86400)
  ok(select(2, claims.parse_duration("2d")):find("at most 24 hours", 1, true), "a claim is bounded")
  ok(select(2, claims.parse_duration("soon")), "not a duration")
  ok(select(2, claims.parse_duration("0m")), "not zero")
  ok(claims.now():match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))

  -- ── names ──────────────────────────────────────────────────────────────────
  ok(claims.valid_name("cdx:3f9a1c7e"))
  ok(claims.valid_name("stefan@steves-pc"))
  ok(not claims.valid_name(""))
  ok(not claims.valid_name("two words"))
  ok(not claims.valid_name(string.rep("a", 65)))
  ok(not claims.valid_name("a/b"))
  ok(
    claims.valid_name(claims.default_name()),
    "the default name is a name: " .. claims.default_name()
  )

  -- ── the state ──────────────────────────────────────────────────────────────
  local c = { by = "a", since = "2026-11-07T10:00:00Z", until_ = "2026-11-07T14:00:00Z" }
  eq(claims.state(nil, "a", "2026-11-07T11:00:00Z"), "free")
  eq(claims.state(c, "a", "2026-11-07T11:00:00Z"), "own")
  eq(claims.state(c, "b", "2026-11-07T11:00:00Z"), "foreign")
  eq(claims.state(c, "b", "2026-11-07T14:00:00Z"), "expired", "the end itself is over")
  eq(claims.state(c, "a", "2026-11-07T15:00:00Z"), "expired")

  -- ── a vault with tasks ─────────────────────────────────────────────────────
  local root = F.vault(H)
  local TODAY = "2026-11-07"
  local function task(slug, status, extra)
    local meta = F.meta("Task " .. slug, status or "open", {
      { "created", "2026-09-01" },
      { "updated", "2026-09-02" },
    })
    vim.list_extend(meta, extra or {})
    F.task(H, root, "lib.nvim", slug, meta, "\nBody of " .. slug .. ".\n\n## Notizen\n\n")
    return "lib.nvim/" .. slug
  end
  local o = { root = root, today = TODAY, index = false }
  local T0 = "2026-01-07T10:00:00Z"
  local T2 = "2026-01-07T15:00:00Z"
  local function with(extra)
    return vim.tbl_extend("force", o, extra)
  end

  -- reading and judging create no folder (ENG-10)
  local id = task("alpha")
  ok(not vim.uv.fs_stat(root .. "/.claims"), "no claims folder yet")
  eq(claims.list(root), {})
  eq(claims.read(root, id), nil)
  ok(claims.guard(root, id, { by = "x" }))
  ok(next_pick.pick_from_vault({ root = root }))
  ok(not vim.uv.fs_stat(root .. "/.claims"), "reading, judging and `next` make no folder")

  -- ── claim ──────────────────────────────────────────────────────────────────
  local res = assert(claims.acquire(id, with({ by = "chat-1", for_ = "2h", now = T0 })))
  eq(res.claim, { by = "chat-1", since = T0, until_ = "2026-01-07T12:00:00Z" })
  eq(scan.find(id, { root = root }).status, "doing", "the visible sign")
  ok(H.exists(root .. "/.claims/lib.nvim/alpha.json"))
  eq(H.read(root .. "/.claims/.gitignore"), "*\n", "the claims never reach git")
  local stored = claims.read(root, id)
  eq(stored.by, "chat-1")
  eq(claims.list(root)[id].until_, "2026-01-07T12:00:00Z")

  -- the same name again renews (the start stays), another name is refused with the owner's name
  local renewed = assert(claims.acquire(id, with({ by = "chat-1", for_ = "3h", now = T0 })))
  eq(renewed.renewed, true)
  eq(renewed.claim.since, T0)
  eq(renewed.claim.until_, "2026-01-07T13:00:00Z")
  local refused, rerr, rinfo = claims.acquire(id, with({ by = "chat-2", now = T0 }))
  eq(refused, nil)
  has(rerr, "is claimed by chat-1")
  has(rerr, "until 2026-01-07T13:00:00Z")
  eq(rinfo.code, "conflict")
  has(
    select(2, claims.acquire(id, with({ by = "chat-2", renew = true, now = T0 }))),
    "no claim of yours to renew"
  )
  has(
    select(2, claims.acquire(id, with({ by = "chat-1", renew = true, for_ = "9d", now = T0 }))),
    "at most 24 hours"
  )
  has(select(2, claims.acquire(id, with({ by = "bad name" }))), "is not a name")
  eq(claims.read(root, id).by, "chat-1", "a refused claim changes nothing")

  -- an expired claim is taken over, and the caller is told whose it was
  local taken = assert(claims.acquire(id, with({ by = "chat-2", now = T2 })))
  eq(taken.taken_over.by, "chat-1")
  eq(claims.read(root, id).by, "chat-2")
  -- --renew of a name that holds none is an error
  local lone = task("lone")
  has(
    select(2, claims.acquire(lone, with({ by = "chat-1", renew = true }))),
    "no claim of yours to renew"
  )
  eq(scan.find(lone, { root = root }).status, "open", "nothing was changed")
  eq(claims.read(root, lone), nil)

  -- ── the guard of the write paths ───────────────────────────────────────────
  local now_ok = claims.now()
  local until_future = claims.add_seconds(now_ok, 3600)
  local guarded = task("guarded")
  assert(claims.acquire(guarded, with({ by = "chat-1", for_ = "1h" })))
  ok(
    claims.read(root, guarded).until_ >= until_future:sub(1, 16),
    "a claim from now runs into the future"
  )
  local _, serr, sinfo = mutate.set(guarded, { prio = "1" }, with({ by = "chat-2" }))
  has(serr, "is claimed by chat-1")
  eq(sinfo.code, "conflict")
  ok(
    not H.read(scan.find(guarded, { root = root }).path):find("prio: 1", 1, true),
    "nothing was written"
  )
  ok(mutate.set(guarded, { prio = "1" }, with({ by = "chat-1" })), "the owner may")
  -- text edits go through the same guard
  local text_edit = function(by, extra)
    return mutate.edit_text(guarded, function(text)
      return text .. "x\n"
    end, with(vim.tbl_extend("force", { by = by }, extra or {})))
  end
  eq(select(1, text_edit("chat-2")), nil)
  ok(text_edit("chat-1"))
  -- force needs a reason, and the override is written down
  has(
    select(2, mutate.set(guarded, { prio = "2" }, with({ by = "chat-2", force = true }))),
    "needs --note"
  )
  ok(
    mutate.set(guarded, { prio = "2" }, with({ by = "chat-2", force = true, note = "chat-1 died" }))
  )
  local before = claims.read(root, guarded)
  ok(
    claims.record_override(
      guarded,
      before,
      with({ by = "chat-2", force = true, note = "chat-1 died" })
    )
  )
  has(
    H.read(scan.find(guarded, { root = root }).path),
    "claim of chat-1 overridden by chat-2: chat-1 died"
  )
  -- attach and folderize
  local src = H.tmpdir() .. "/pic.txt"
  H.write(src, "x")
  has(select(2, mutate.attach(guarded, src, with({ by = "chat-2" }))), "is claimed by chat-1")
  has(select(2, mutate.folderize(guarded, with({ by = "chat-2" }))), "is claimed by chat-1")
  -- the finish
  has(select(2, mutate.done(guarded, with({ by = "chat-2" }))), "is claimed by chat-1")
  has(select(2, mutate.done_preview(guarded, with({ by = "chat-2" }))), "is claimed by chat-1")
  ok(scan.find(guarded, { root = root }), "still open")
  -- a task of nobody's, and an expired claim, may be changed by anyone
  ok(mutate.set(lone, { prio = "3" }, with({ by = "chat-2" })))
  ok(
    mutate.set(id, { prio = "3" }, with({ by = "chat-3" })),
    "the claim of chat-2 is expired for the real clock"
  )
  -- the owner finishes: the claim goes with the task
  local flow = assert(mutate.done(guarded, with({ by = "chat-1" })))
  ok(flow.to:find("Backlog", 1, true))
  eq(claims.read(root, guarded), nil, "a finished task has no claim")
  ok(not H.exists(root .. "/.claims/lib.nvim/guarded.json"))

  -- ── unclaim ────────────────────────────────────────────────────────────────
  local held = task("held")
  assert(claims.acquire(held, with({ by = "chat-1" })))
  has(select(2, claims.release(held, with({ by = "chat-2" }))), "is claimed by chat-1")
  local freed = assert(claims.release(held, with({ by = "chat-1" })))
  eq(freed.released, true)
  eq(freed.status, "open", "doing goes back to open")
  eq(claims.read(root, held), nil)
  eq(scan.find(held, { root = root }).status, "open")
  eq(
    assert(claims.release(held, with({ by = "chat-1" }))).released,
    false,
    "nothing to give back is no error"
  )
  assert(claims.acquire(held, with({ by = "chat-1" })))
  assert(claims.release(held, with({ by = "chat-2", force = true, note = "stuck" })))
  eq(claims.read(root, held), nil, "force takes it away")
  assert(claims.acquire(held, with({ by = "chat-1" })))
  eq(assert(claims.release(held, with({ by = "chat-1", status = "parked" }))).status, "parked")

  -- ── next leaves out what somebody else works on ────────────────────────────
  local n_a, n_b =
    task("n-first", "open", { { "prio", "1" } }), task("n-second", "open", { { "prio", "2" } })
  assert(claims.acquire(n_a, with({ by = "chat-1" })))
  local mine = assert(next_pick.pick_from_vault({ root = root, by = "chat-1" }))
  eq(mine.task.id, n_a, "the owner sees the task (doing comes first)")
  local others = assert(next_pick.pick_from_vault({ root = root, by = "chat-2" }))
  ok(others.task.id ~= n_a, "another chat is not offered it")
  eq(others.claimed, 1, "and is told how many were left out")
  has(
    table.concat(require("tasks_nvim.plan_view").next_lines(others), "\n"),
    "claimed: 1 task(s) left out"
  )
  ok(n_b)

  -- ── check ──────────────────────────────────────────────────────────────────
  local check = require("tasks_nvim.check")
  local function codes(res2)
    local out = {}
    for _, f in ipairs(res2.findings) do
      out[f.code] = (out[f.code] or 0) + 1
    end
    return out
  end
  local expired = task("expired")
  assert(
    claims.acquire(expired, with({ by = "chat-9", now = "2026-01-01T10:00:00Z", for_ = "1h" }))
  )
  H.write(
    root .. "/.claims/lib.nvim/ghost.json",
    '{"by":"chat-9","since":"2026-01-07T10:00:00Z","until":"2026-01-07T14:00:00Z"}\n'
  )
  local stale_doing = task("stale-doing", "doing", { { "updated", "2026-10-01" } })
  local fresh_doing = task("fresh-doing", "doing", { { "updated", "2026-11-07" } })
  local found = codes(assert(check.run({ root = root, today = TODAY })))
  eq(found["claim-expired"], 2, "the expired claims (alpha, taken over in the past, and this one)")
  eq(found["claim-orphan"], 1, "a claim of a task that is not open")
  ok(found["doing-unclaimed"] >= 1, "a doing task nobody claimed for days")
  local doing_ids = {}
  for _, f in ipairs(assert(check.run({ root = root, today = TODAY })).findings) do
    if f.code == "doing-unclaimed" then
      doing_ids[f.id] = true
    end
  end
  ok(doing_ids[stale_doing], "the old doing task")
  ok(not doing_ids[fresh_doing], "a doing task of today")
  ok(not doing_ids[n_a], "a claimed task is no finding")
  ok(
    not codes(assert(check.run({ root = root, today = TODAY, area = "cascade.nvim" })))["claim-orphan"],
    "other area"
  )

  -- ── the contract ───────────────────────────────────────────────────────────
  local contract = require("tasks_nvim.contract")
  local snap = assert(contract.snapshot({ root = root }))
  local entry
  for _, t in ipairs(snap.tasks) do
    if t.id == n_a then
      entry = t
    end
  end
  eq(entry.claim.by, "chat-1")
  eq(entry.claim.expired, false)
  -- a timestamp of the engine, not the day of `now`: a claim of four hours lies on the next UTC day late in the evening
  ok(entry.claim["until"]:match("^%d%d%d%d%-%d%d%-%d%dT") ~= nil, "`until` is a timestamp")
  for _, t in ipairs(snap.tasks) do
    if t.id == n_a then
      ok(t.claim ~= nil)
    elseif t.id == held then
      ok(t.claim == nil, "no claim, no field")
    end
  end
  local rev_with = snap.rev
  claims.remove(root, n_a)
  eq(
    assert(contract.snapshot({ root = root })).rev ~= rev_with,
    true,
    "a claim is part of the revision"
  )
  assert(claims.acquire(n_a, with({ by = "chat-1" })))
  local nxt = assert(contract.next({}, { root = root }))
  ok(nxt.claimed == nil or nxt.claimed >= 1)

  -- ── the ops door ───────────────────────────────────────────────────────────
  local api = require("tasks_nvim.api")
  local function ops(list)
    local text = api.call("ops", vim.json.encode({ ops = list }), { root = root, today = TODAY })
    return vim.json.decode(text)
  end
  local door_id = task("door")
  local claimed_doc = ops({ { op = "claim", id = door_id, by = "ui-1", ["for"] = "1h" } })
  eq(claimed_doc.kind, "tasks.result", vim.inspect(claimed_doc))
  eq(claimed_doc.results[1].outcome, "changed", vim.inspect(claimed_doc.results[1]))
  eq(claims.read(root, door_id).by, "ui-1")
  local refused_doc = ops({ { op = "set", id = door_id, patch = { prio = "1" }, by = "ui-2" } })
  eq(refused_doc.results[1].ok, false)
  eq(refused_doc.results[1].error.code, "conflict")
  has(refused_doc.results[1].error.message, "is claimed by ui-1")
  local ok_doc = ops({ { op = "set", id = door_id, patch = { prio = "1" }, by = "ui-1" } })
  eq(ok_doc.results[1].ok, true, vim.inspect(ok_doc.results[1]))
  local forced =
    ops({ { op = "set", id = door_id, patch = { prio = "2" }, by = "ui-2", force = true } })
  eq(forced.results[1].ok, false, "force needs a note")
  local dry = ops({ { op = "claim", id = door_id, by = "ui-2" } })
  eq(dry.results[1].ok, false, "a claimed task cannot be claimed")
  local gave = ops({ { op = "release", id = door_id, by = "ui-1" } })
  eq(gave.results[1].ok, true, vim.inspect(gave.results[1]))
  eq(claims.read(root, door_id), nil)
  eq(ops({ { op = "claim", id = "lib.nvim/nope" } }).results[1].error.code, "not_found")
  -- the identity of one operation never leaks into the next call
  eq(claims.identity, nil)

  -- ── the CLI ────────────────────────────────────────────────────────────────
  local cli = require("tasks_nvim.cli")
  local function run(argv)
    local out, err = {}, {}
    local code =
      cli.run(vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=" .. TODAY }), {
        out = function(t)
          out[#out + 1] = t
        end,
        err = function(t)
          err[#err + 1] = t
        end,
      })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  local cli_id = task("by-cli")
  local c1 = run({ "claim", cli_id, "--by=agent-a", "--for=30m" })
  eq(c1.code, 0, c1.err)
  has(c1.out, "claimed\t" .. cli_id .. "\tagent-a\t")
  local c2 = run({ "claim", cli_id, "--by=agent-b" })
  eq(c2.code, 1)
  has(c2.err, "is claimed by agent-a")
  local s1 = run({ "set", cli_id, "prio=1", "--by=agent-b" })
  eq(s1.code, 1)
  has(s1.err, "is claimed by agent-a")
  local s2 = run({ "set", cli_id, "prio=1", "--by=agent-a" })
  eq(s2.code, 0, s2.err)
  local s3 = run({ "set", cli_id, "prio=2", "--by=agent-b", "--force", "--note=agent-a stopped" })
  eq(s3.code, 0, s3.err)
  has(
    H.read(scan.find(cli_id, { root = root }).path),
    "claim of agent-a overridden by agent-b: agent-a stopped"
  )
  local shown = run({ "show", cli_id })
  has(shown.out, "claim: agent-a since ")
  local nx = run({ "next", "--by=agent-b" })
  has(nx.out, "claimed: ")
  local u1 = run({ "unclaim", cli_id, "--by=agent-b" })
  eq(u1.code, 1)
  local u2 = run({ "unclaim", cli_id, "--by=agent-a" })
  eq(u2.code, 0, u2.err)
  has(u2.out, "unclaimed\t" .. cli_id .. "\topen")
  eq(run({ "claim" }).code, 2)
  -- `release <key>` is still the verb of the parked tasks
  ok(run({ "release", "no-such-key" }).code ~= 2, "release is still a known verb")

  -- ── two processes claim the same task: exactly one wins ────────────────────
  local lib = vim.env.LIB_NVIM_DIR
  if lib and lib ~= "" then
    local race_id = task("race")
    local script = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
      .. "/scripts/tasks.lua"
    local procs = {}
    for i = 1, 4 do
      procs[i] = vim.system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-l",
        script,
        "claim",
        race_id,
        "--by=racer-" .. i,
        "--vault=" .. root,
      }, { text = true, env = { LIB_NVIM_DIR = lib } })
    end
    local winners = 0
    for i = 1, 4 do
      local r = procs[i]:wait(60000)
      if r.code == 0 then
        winners = winners + 1
      else
        has((r.stderr or "") .. (r.stdout or ""), "is claimed by racer-", "a loser is told who won")
      end
    end
    eq(winners, 1, "exactly one process wins the claim")
  end

  -- ── reorder, the finish with an override, `list --ready` ───────────────────
  local batch = require("tasks_nvim.batch")
  local ro_a = task("ro-a", "open", { { "prio", "2" } })
  local ro_b = task("ro-b", "open", { { "prio", "2" } })
  assert(claims.acquire(ro_a, with({ by = "chat-1" })))
  local _, rerr2, rinfo2 = batch.reorder(ro_a, { after = ro_b }, with({ by = "chat-2" }))
  has(rerr2, "is claimed by chat-1", "reorder asks the claim too")
  eq(rinfo2.code, "conflict")
  local door_reorder = ops({ { op = "reorder", id = ro_a, after = ro_b, by = "ui-2" } })
  eq(door_reorder.results[1].ok, false, "also through the door")
  has(door_reorder.results[1].error.message, "is claimed by chat-1")

  local fin = task("fin")
  assert(claims.acquire(fin, with({ by = "chat-1" })))
  local fin_flow = assert(
    require("tasks_nvim.done_flow").run(
      fin,
      with({ by = "chat-2", force = true, note = "chat-1 died", pick_next = false })
    )
  )
  has(
    H.read(fin_flow.done.to),
    "claim of chat-1 overridden by chat-2: chat-1 died",
    "the override is in the finished task"
  )
  eq(claims.read(root, fin), nil)

  local ready_a, ready_b = task("ready-a"), task("ready-b")
  assert(claims.acquire(ready_a, with({ by = "chat-1" })))
  local plan_scope = require("tasks_nvim.plan_scope")
  local open_tasks = assert(scan.all({ root = root }))
  local function ready_for(by)
    local kept = assert(plan_scope.filter_readiness(open_tasks, "ready", root, nil, TODAY, by))
    local ids = {}
    for _, t in ipairs(kept) do
      ids[t.id] = true
    end
    return ids
  end
  ok(not ready_for("chat-2")[ready_a], "list --ready: not ready for another name")
  ok(ready_for("chat-2")[ready_b], "an unclaimed task is")
  ok(ready_for("chat-1")[ready_a], "the owner sees his own")
  local listed = run({ "list", "lib.nvim", "--ready", "--format=ids", "--by=chat-2" })
  ok(not listed.out:find(ready_a, 1, true), "the CLI list: " .. listed.out)
  ok(listed.out:find(ready_b, 1, true))

  -- ── the editor: `:Tasks claim` and `:Tasks unclaim` (the same engine, the words of the editor) ──────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  require("tasks_nvim.vault").set_root(root)
  local told = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    told[#told + 1] = tostring(msg)
  end
  local function said()
    local all = table.concat(told, "\n")
    told = {}
    return all
  end
  local ed = task("editor-claim")
  cmd.task_claim({
    rest = {},
    args = { id = ed },
    kv = { by = "me@here", ["for"] = "2h" },
    flags = {},
  })
  has(said(), "claimed " .. ed .. " for me@here until")
  eq(claims.read(root, ed).by, "me@here")
  eq(scan.find(ed, { root = root }).status, "doing")
  -- again with the same name: a claim of one's own is renewed only with --renew, else it is just made again
  cmd.task_claim({
    rest = {},
    args = { id = ed },
    kv = { by = "me@here" },
    flags = { renew = true },
  })
  has(said(), "renewed " .. ed)
  -- another name is refused and nothing changes; --force without a note is refused too
  cmd.task_claim({ rest = {}, args = { id = ed }, kv = { by = "other@there" }, flags = {} })
  has(said(), "is claimed by me@here")
  cmd.task_claim({
    rest = {},
    args = { id = ed },
    kv = { by = "other@there" },
    flags = { force = true },
  })
  ok(said() ~= "", "--force without a note says why not")
  eq(claims.read(root, ed).by, "me@here", "a refused claim changes nothing")
  -- a stray word and a bad duration are said, and nothing is claimed
  local plain = task("editor-plain")
  cmd.task_claim({ rest = { "oops" }, args = { id = plain }, kv = {}, flags = {} })
  has(said(), "unexpected argument: oops")
  cmd.task_claim({ rest = {}, args = { id = plain }, kv = { ["for"] = "9d" }, flags = {} })
  has(said(), "at most 24 hours")
  eq(claims.read(root, plain), nil, "nothing was claimed")
  -- unclaim: somebody else's claim is refused, the owner gives it back, the status returns
  cmd.task_unclaim({ rest = {}, args = { id = ed }, kv = { by = "other@there" }, flags = {} })
  ok(said() ~= "", "a claim of somebody else is refused")
  eq(claims.read(root, ed).by, "me@here")
  cmd.task_unclaim({
    rest = {},
    args = { id = ed },
    kv = { by = "me@here", status = "parked" },
    flags = {},
  })
  has(said(), "unclaimed " .. ed .. ": parked")
  eq(claims.read(root, ed), nil, "the claim is gone")
  eq(scan.find(ed, { root = root }).status, "parked")
  vim.notify = real_notify
end
