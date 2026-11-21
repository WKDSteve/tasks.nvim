-- TESTS/tasks_paths_xp_spec.lua -- XP and levels of a learning path on disk: the XP of a promoted task (open and
-- finished) win over the point's, the level state of the file, `paths.set_reward` (byte for byte, refused without a
-- reward, if_match, dry run), the XP of a point written with `paths.point`, and the `check` findings (level problems,
-- a missing badge, `xp-missing` as a hint, none of it for a path without levels).
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local done_flow = require("tasks_nvim.done_flow")
  local mutate = require("tasks_nvim.mutate")
  local paths = require("tasks_nvim.paths")

  local TODAY = "2026-11-20"
  local root = F.vault(H)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local A = "lib.nvim"

  local cc = assert(mutate.new(A, vim.tbl_extend("force", o, { title = "C-Compiler", xp = 60 })))
  eq(cc.id, A .. "/c-compiler")

  local dir = root .. "/" .. A .. "/ROADMAP/paths/lua-lernen"
  local file = dir .. "/lua-lernen.md"
  H.write(dir .. "/assets/badges/stern.png", "png")
  local TEXT = table.concat({
    "---",
    "title: Lua lernen",
    "status: doing",
    "updated: 2026-11-19",
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lua lernen {#lua}",
    "  - [x] Manual {xp=20}",
    "  - [~] PIL – Grund: nur Kap. 1 {xp=20}",
    "  - [ ] C-Compiler → lib.nvim/c-compiler {xp=40} {#cc}",
    "  - [ ] Ohne XP {#plain}",
    "",
    "## Level",
    "",
    "- [ ] 20 XP · Badge assets/badges/stern.png · Belohnung: großes Eis kaufen",
    "- [ ] 50 % · Badge assets/badges/mond.svg · Belohnung: Kino",
    "- [ ] 40 XP · Belohnung: Buch",
    "- [ ] 90 XP",
    "- [ ] Pfad fertig · Belohnung: Wochenende am See",
    "",
  }, "\n")
  H.write(file, TEXT)

  -- ── the XP of the open task win over the point's {xp=40} ──
  local p = assert(paths.find(A .. "/lua-lernen", { root = root }))
  eq(p.tree.by_key.cc.xp, 60)
  eq(p.tree.by_key.cc.xp_from, "task")
  eq(p.tree.xp, { earned = 30, possible = 100, open = 60, points = 3, missing = 1 })
  eq(p.level_state.level, 1)
  eq(p.level_state.percent, 30)
  eq(p.level_state.next, { number = 2, missing_xp = 20 })
  eq(p.level_state.open_rewards, { { ref = "1", reward = "großes Eis kaufen" } })
  local listed = assert(paths.area(A, { root = root }))
  eq(listed[1].tree.by_key.cc.xp, 60, "the listing has the task XP too")

  -- a task without xp: the point's own count
  assert(mutate.set(cc.id, { xp = mutate.REMOVE }, o))
  eq(assert(paths.find(A .. "/lua-lernen", { root = root })).tree.by_key.cc.xp, 40)
  assert(mutate.set(cc.id, { xp = "60" }, o))

  -- ── set_reward ──
  local r = assert(paths.set_reward(A .. "/lua-lernen", 1, true, o))
  eq(r.changed, true)
  eq(r.level, { ref = "1", line = 12, given = true, before = false }, "the line of the body")
  local after = H.read(file)
  eq(
    after,
    (TEXT:gsub("%- %[ %] 20 XP", "- [x] 20 XP"):gsub("updated: 2026%-11%-19", "updated: " .. TODAY))
  )
  eq(assert(paths.find(A .. "/lua-lernen", { root = root })).level_state.open_rewards, {})
  -- again: nothing to change
  eq(assert(paths.set_reward(A .. "/lua-lernen", "1", true, o)).changed, false)
  -- a dry run writes nothing; a stale version is refused
  eq(
    assert(
      paths.set_reward(
        A .. "/lua-lernen",
        "done",
        true,
        vim.tbl_extend("force", o, { dry_run = true })
      )
    ).changed,
    true
  )
  eq(H.read(file), after)
  local _, cerr, cinfo = paths.set_reward(
    A .. "/lua-lernen",
    "done",
    true,
    vim.tbl_extend("force", o, { if_match = "nope" })
  )
  eq(cinfo.code, "conflict", cerr)
  local _, nerr, ninfo = paths.set_reward(A .. "/lua-lernen", 4, true, o)
  eq(ninfo.code, "invalid_argument")
  has(nerr, "no reward")
  eq(select(3, paths.set_reward(A .. "/nope", 1, true, o)).code, "not_found")
  eq(select(3, paths.set_reward(A .. "/lua-lernen", 1, "yes", o)).code, "invalid_argument")

  -- ── the XP of a point with paths.point ──
  local pt = assert(
    paths.point(A .. "/lua-lernen", "plain", nil, nil, vim.tbl_extend("force", o, { xp = 15 }))
  )
  eq(pt.node.xp, 15)
  has(H.read(file), "  - [ ] Ohne XP {xp=15} {#plain}")
  local _, xerr =
    paths.point(A .. "/lua-lernen", "plain", nil, nil, vim.tbl_extend("force", o, { xp = "viel" }))
  has(xerr, "whole number")

  -- ── check ──
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
  -- the plain point has XP now; a new one without
  H.write(file, (H.read(file):gsub("## Level", "  - [ ] Noch eins\n\n## Level", 1)))
  local res = assert(check.run({ root = root, area = A }))
  eq(codes(res.findings, A .. "/lua-lernen"), { "level-badge-missing", "level-order" })
  eq(codes(res.hints, A .. "/lua-lernen"), { "xp-missing" })
  local hint
  for _, h in ipairs(res.hints) do
    if h.code == "xp-missing" then
      hint = h
    end
  end
  -- the line of the file, frontmatter counted
  local new_line
  for i, l in ipairs(vim.split(H.read(file), "\n", { plain = true })) do
    if l:find("Noch eins", 1, true) then
      new_line = i
    end
  end
  has(hint.message, ("1 learning point(s) without XP (line %d)"):format(new_line))

  -- a path without levels: no level findings, no hint
  H.write(
    root .. "/" .. A .. "/ROADMAP/paths/plain.md",
    "---\ntitle: Plain\nstatus: doing\nupdated: 2026-11-19\n---\n\n## Lernpunkte\n\n- [ ] a\n- [ ] b {xp=bad}\n"
  )
  res = assert(check.run({ root = root, area = A }))
  eq(codes(res.findings, A .. "/plain"), { "path-bad-xp" })
  eq(codes(res.hints, A .. "/plain"), {})
  ok(res.ok, "warnings and hints only")

  -- ── a finished task counts too ──
  assert(mutate.set(cc.id, { point = A .. "/lua-lernen#cc" }, o))
  assert(done_flow.run(cc.id, vim.tbl_extend("force", o, { pick_next = false })))
  p = assert(paths.find(A .. "/lua-lernen", { root = root }))
  eq(p.tree.by_key.cc.state, "learned", "done wrote the mark")
  eq(p.tree.by_key.cc.xp, 60, "the finished task's XP")
end
