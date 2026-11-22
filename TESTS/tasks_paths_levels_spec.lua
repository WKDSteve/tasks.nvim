-- TESTS/tasks_paths_levels_spec.lua -- every level of every path in one request (`tasks.paths` with `levels: true`,
-- capability `paths_levels`): no field without the option or without `## Level`, what is missing to an open level,
-- the days from the series of the learning figures (only while reached / granted), a held path's whole-path line
-- open, a new rev when the series changes. The document itself is the golden `paths-levels`.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local lh = require("tasks_nvim.learn_history")

  local root = F.vault(H)
  local P = root .. "/lib.nvim/ROADMAP/paths"
  H.write(
    P .. "/xp.md",
    table.concat({
      "---",
      "title: XP",
      "status: doing",
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [x] Eins {xp=30}",
      "- [ ] Zwei {xp=30}",
      "- [ ] Drei {xp=40}",
      "",
      "## Level",
      "",
      "- [x] 30 XP · Start · Belohnung: Tee",
      "- [ ] 50 % · Halb",
      "- [ ] 90 XP · Viel · Belohnung: Kuchen",
      "- [ ] Pfad fertig",
      "",
    }, "\n")
  )
  H.write(
    P .. "/ohne-xp.md",
    table.concat({
      "---",
      "title: Ohne XP",
      "status: doing",
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [x] Eins",
      "- [ ] Zwei",
      "- [ ] Drei",
      "- [ ] Vier",
      "",
      "## Level",
      "",
      "- [ ] 50 % · Halb",
      "",
    }, "\n")
  )
  H.write(P .. "/kahl.md", "---\ntitle: Kahl\nstatus: doing\n---\n\n## Lernpunkte\n\n- [ ] A\n")

  local function call(params)
    local doc = vim.json.decode((api.call("paths", { params = params or {} }, { root = root })))
    local by = {}
    for _, it in ipairs(doc.items or {}) do
      by[it.id] = it
    end
    return doc, by
  end
  ok(
    vim.tbl_contains(
      vim.json.decode((api.call("hello", {}, { root = root }))).capabilities,
      "paths_levels"
    )
  )
  local _, plain = call()
  eq(plain["lib.nvim/xp"].levels, nil, "no levels without the option")
  local doc, by = call({ levels = true })
  eq(by["lib.nvim/kahl"].levels, nil, "no levels without ## Level")
  local lv = by["lib.nvim/xp"].levels
  eq(#lv, 4)
  eq({ lv[1].ref, lv[1].reached, lv[1].missing_xp }, { "1", true, nil })
  eq(lv[2].missing_xp, 20, "50 % of 100 XP is 50, 30 earned")
  eq(lv[3].missing_xp, 60)
  eq(
    { lv[4].ref, lv[4].missing_percent },
    { "done", 70 },
    "the whole path: the percent missing (of the XP: 30 of 100)"
  )
  eq(lv[1].reached_on, nil, "no series: no day")
  eq(by["lib.nvim/ohne-xp"].levels[1].missing_percent, 25, "without XP: the percent missing")

  -- the series knows the days; a day is only there while the level is reached / the reward granted
  local dir = root .. "/_Telemetry/history"
  vim.fn.mkdir(dir, "p")
  local function series(rows)
    local lines = {}
    for _, r in ipairs(rows) do
      lines[#lines + 1] = lh.encode_row(vim.tbl_extend("force", {
        path = "lib.nvim/xp",
        area = "lib.nvim",
        learned = 1,
        seen = 0,
        dropped = 0,
        open = 2,
        total = 3,
        xp = 30,
        done_h = 0,
      }, r))
    end
    H.write(dir .. "/learn-2026-01.jsonl", table.concat(lines, "\n") .. "\n")
  end
  series({
    { day = "2026-01-02", at = "2026-01-02T08:00:00Z", level = 1, reached = { "1", "3" } },
    {
      day = "2026-01-03",
      at = "2026-01-03T08:00:00Z",
      level = 1,
      reached = { "1", "3" },
      given = { "1", "3" },
    },
  })
  local doc2, by2 = call({ levels = true })
  local lv2 = by2["lib.nvim/xp"].levels
  eq(lv2[1].reached_on, "2026-01-02")
  eq(lv2[1].given_on, "2026-01-03", "granted in the file: the day the series first saw it")
  ok(doc2.rev ~= doc.rev, "the series is part of the rev")
  eq(lv2[3].reached_on, nil, "level 3 is not reached now: no day, whatever the series says")
  eq(lv2[3].given_on, nil, "nor granted in the file")

  -- a path that waits under the hard gate keeps its whole-path line open
  H.write(
    P .. "/warte.md",
    "---\ntitle: Warte\nstatus: doing\nrequires: [lib.nvim/kahl]\nrequires_gate: hard\n---\n\n"
      .. "## Lernpunkte\n\n- [x] A\n\n## Level\n\n- [ ] Pfad fertig\n"
  )
  local _, by4 = call({ levels = true })
  eq(by4["lib.nvim/warte"].levels[1].reached, false, "held by what it waits for")
end
