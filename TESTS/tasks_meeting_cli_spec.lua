-- TESTS/tasks_meeting_cli_spec.lua -- the headless verbs of meetings: `meeting new` (options, `--quick`, a dry run, a
-- refusal), `meeting set` (an empty value removes), `meeting attend`, `meeting followups`, `meeting close`,
-- `meeting show`, `meeting parse` and `meetings`.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local meetings = require("tasks_nvim.meetings")

  local root = F.vault(H)
  meetings.reset_cache()
  F.task(H, root, "lib.nvim", "prep", F.meta("Prep", "open"))
  local common = { "--vault=" .. root, "--today=" .. F.TODAY }

  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(vim.deepcopy(argv), common), {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local function file(id)
    meetings.reset_cache()
    return assert(meetings.find(id, { root = root }))
  end

  -- new: a dry run, then for real
  local dry = run({
    "meeting",
    "new",
    "lib.nvim",
    "Sync",
    "--date=2026-10-20",
    "--time=14:00",
    "--duration=45m",
    "--tasks=lib.nvim/prep",
    "--dry-run",
  })
  eq(dry.code, 0, dry.err)
  has(dry.out, "would_create\tlib.nvim/sync-2026-10-20")
  ok(not vim.uv.fs_stat(root .. "/lib.nvim/MEETINGS/sync-2026-10-20.md"))
  local made = run({
    "meeting",
    "new",
    "lib.nvim",
    "Sync",
    "--date=2026-10-20",
    "--time=14:00",
    "--duration=45m",
    "--tasks=lib.nvim/prep",
    "--notify=-15m,-1d@18:00",
  })
  eq(made.code, 0, made.err)
  local id = "lib.nvim/sync-2026-10-20"
  eq(file(id).duration_min, 45)
  eq(#file(id).notify, 2)
  -- --quick: the line, the options win over it
  local q = run({
    "meeting",
    "new",
    "lib.nvim",
    "--quick=Mo 10:00-11:00 Retro @Raum_1 !-15m",
    "--location=Raum 2",
  })
  eq(q.code, 0, q.err)
  local retro = file("lib.nvim/retro-2026-10-05")
  eq(retro.time, "10:00")
  eq(retro.location, "Raum 2")
  -- a refusal: no date, an end before the beginning
  eq(run({ "meeting", "new", "lib.nvim", "No date" }).code, 2)
  local bad =
    run({ "meeting", "new", "lib.nvim", "Bad", "--date=2026-10-20", "--time=10:00", "--end=09:00" })
  eq(bad.code, 2)
  has(bad.err, "not after the beginning")

  -- set: a field, then removed with an empty value
  eq(run({ "meeting", "set", id, "--location=Raum 3.14" }).code, 0)
  eq(file(id).location, "Raum 3.14")
  eq(run({ "meeting", "set", id, "--location=" }).code, 0)
  eq(file(id).location, nil)
  eq(run({ "meeting", "set", id }).code, 2)

  -- attend and followups (participants and a follow-up written by hand)
  local path = file(id).path
  local text = H.read(path):gsub("## Teilnehmer\n", "## Teilnehmer\n\n- [ ] Rick\n- [ ] Stefan\n")
  text = text:gsub("## Folgeaufgaben\n", "## Folgeaufgaben\n\n- [ ] Lizenz klären\n")
  H.write(path, text)
  eq(run({ "meeting", "attend", id, "Rick" }).code, 0)
  eq(run({ "meeting", "attend", id, "2" }).code, 0)
  eq(run({ "meeting", "attend", id, "2", "--absent" }).code, 0)
  eq(file(id).participants[1].present, true)
  eq(file(id).participants[2].present, false)
  local fu = run({ "meeting", "followups", id })
  eq(fu.code, 0, fu.err)
  has(fu.out, "task\t1\tlib.nvim/lizenz-klaeren")
  eq(file(id).followups[1].task, "lib.nvim/lizenz-klaeren")

  -- show
  local show = run({ "meeting", "show", id })
  eq(show.code, 0, show.err)
  has(show.out, "participant\t1\tx\tRick")
  has(show.out, "followup\t1\t \tLizenz klären\tlib.nvim/lizenz-klaeren")
  local json = run({ "meeting", "show", id, "--format=json" })
  eq(vim.json.decode(json.out).kind, "tasks.meeting")

  -- close without a result, then meetings lists it
  local close = run({ "meeting", "close", id })
  eq(close.code, 0, close.err)
  has(close.out, "without-result\t" .. id)
  eq(file(id).status, "done")
  local list = run({ "meetings", "lib.nvim", "--since=2026-10-01", "--until=2026-10-31" })
  eq(list.code, 0, list.err)
  has(list.out, id)
  has(list.out, "lib.nvim/retro-2026-10-05")
  local only = run({ "meetings", "--task=lib.nvim/prep", "--format=json" })
  eq(#vim.json.decode(only.out).items, 1)

  -- parse
  local parsed =
    vim.json.decode(run({ "meeting", "parse", "morgen", "ganztägig", "Schulung" }).out)
  eq(parsed.title, "Schulung")
  eq(parsed.fields.date, "2026-10-04")

  -- usage
  eq(run({ "meeting" }).code, 2)
  eq(run({ "meeting", "nope" }).code, 2)
  eq(run({ "meeting", "show", "lib.nvim/nope" }).code, 1)
end
