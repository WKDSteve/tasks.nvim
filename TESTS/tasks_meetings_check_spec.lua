-- TESTS/tasks_meetings_check_spec.lua -- what `check` says about the meeting files: their own codes, an id another
-- file of the area has, a task that exists nowhere, a missing image, done before its day, done without a result and
-- two planned meetings at the same time; each with a case that must stay quiet.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local meetings = require("tasks_nvim.meetings")

  local root = F.vault(H)
  local dir = root .. "/lib.nvim/MEETINGS"
  meetings.reset_cache()

  ---@param path string
  ---@param fields string[]
  ---@param body? string
  local function meeting(path, fields, body)
    H.write(path, "---\n" .. table.concat(fields, "\n") .. "\n---\n" .. (body or "Note.\n"))
  end

  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/real.md",
    "---\ntitle: Real\nstatus: open\ncreated: 2026-10-01\n---\n\nA task.\n"
  )
  H.write(
    root .. "/lib.nvim/ROADMAP/tasks/same.md",
    "---\ntitle: Same\nstatus: open\ncreated: 2026-10-01\n---\n\nA task.\n"
  )
  require("tasks_nvim.index").write_area("lib.nvim", { root = root })

  -- quiet: a good meeting naming a real task, with its image, done in the past with a result
  meeting(dir .. "/good/good.md", {
    "title: Good",
    "status: done",
    "date: 2026-10-01",
    "tasks: [lib.nvim/real]",
    "cover: assets/cover.png",
  }, "## Ergebnis\nAgreed.\n")
  H.write(dir .. "/good/assets/cover.png", "png")
  -- loud ones
  meeting(dir .. "/broken.md", { "title: Broken", "status: held", "date: 2026-10-01" })
  meeting(dir .. "/same.md", { "title: Same id", "status: planned", "date: 2026-10-10" })
  -- the id of a finished task is taken too (ids are global: `find` and wikilinks would name two files)
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-10-01_shipped.md",
    "---\ntitle: Shipped\nstatus: done\ncreated: 2026-09-01\n---\n\nDone.\n"
  )
  meeting(dir .. "/shipped.md", { "title: Shipped id", "status: planned", "date: 2026-10-10" })
  meeting(
    dir .. "/dangling.md",
    { "title: Dangling", "status: planned", "date: 2026-10-10", "tasks: [lib.nvim/nowhere]" }
  )
  meeting(
    dir .. "/noimage.md",
    { "title: No image", "status: planned", "date: 2026-10-10", "cover: assets/x.png" }
  )
  meeting(dir .. "/future.md", { "title: Future", "status: done", "date: 2026-12-24" })
  meeting(
    dir .. "/one.md",
    { "title: One", "status: planned", "date: 2026-10-20", 'time: "10:00"', "duration: 1h" }
  )
  meeting(
    dir .. "/two.md",
    { "title: Two", "status: planned", "date: 2026-10-20", 'time: "10:30"', "duration: 30m" }
  )
  meeting(
    dir .. "/after.md",
    { "title: After", "status: planned", "date: 2026-10-20", 'time: "11:00"', "duration: 30m" }
  )

  local res = check.run({ root = root, area = "lib.nvim", today = F.TODAY, ui_words = false })
  ---@param list Tasks.Finding[]
  ---@param id string
  ---@return string[]
  local function codes(list, id)
    local out = {}
    for _, f in ipairs(list) do
      if f.id == id then
        out[#out + 1] = f.code
      end
    end
    table.sort(out)
    return out
  end

  eq(codes(res.findings, "lib.nvim/good"), {}, "a good meeting says nothing")
  eq(codes(res.hints, "lib.nvim/good"), {}, "with a result: no hint")
  eq(codes(res.findings, "lib.nvim/broken"), { "meeting-bad-status" })
  eq(codes(res.findings, "lib.nvim/same"), { "meeting-id-taken" })
  eq(codes(res.findings, "lib.nvim/shipped"), { "meeting-id-taken" }, "a finished task's id")
  eq(codes(res.findings, "lib.nvim/dangling"), { "meeting-task-dangling" })
  eq(codes(res.findings, "lib.nvim/noimage"), { "meeting-image-missing" })
  eq(codes(res.findings, "lib.nvim/future"), { "meeting-done-in-future" })
  eq(codes(res.hints, "lib.nvim/future"), { "meeting-done-without-result" })
  eq(codes(res.hints, "lib.nvim/two"), { "meeting-overlap" })
  eq(
    codes(res.hints, "lib.nvim/after"),
    {},
    "a meeting that begins when the other ends is no overlap"
  )
  eq(codes(res.hints, "lib.nvim/one"), {})
  ok(not res.ok, "a broken meeting fails the run")

  -- a finished task is no dangling one
  H.write(
    root .. "/lib.nvim/Backlog/TASKS/2026-10-02_nowhere.md",
    "---\ntitle: Nowhere\nstatus: done\ncreated: 2026-10-01\n---\n\nDone.\n"
  )
  res = check.run({ root = root, area = "lib.nvim", today = F.TODAY, ui_words = false })
  eq(codes(res.findings, "lib.nvim/dangling"), {}, "a finished task is known")

  -- another area is not checked when one is asked for
  local other = check.run({ root = root, area = "cascade.nvim", today = F.TODAY, ui_words = false })
  eq(codes(other.findings, "lib.nvim/broken"), {})
end
