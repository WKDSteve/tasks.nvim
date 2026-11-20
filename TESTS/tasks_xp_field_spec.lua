-- TESTS/tasks_xp_field_spec.lua -- the `xp:` of a learning task: read by the model (bad-xp for anything but a whole
-- number), written by `new` (also `tasks new --xp=`) and `set` (removed with an empty value), refused when bad, and
-- taken along by `promote` from the `{xp=N}` of the point.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")
  local promote = require("tasks_nvim.promote")
  local cli = require("tasks_nvim.cli")

  local TODAY = "2026-11-20"

  -- ── the model ──
  local function task(extra)
    return model.parse_text(
      F.text(F.meta("x", "open", extra)),
      { path = "/v/a/ROADMAP/tasks/x.md", area = "a" }
    )
  end
  eq(task({ { "xp", "25" } }).xp, 25)
  eq(task({ { "xp", "0" } }).xp, 0)
  eq(task({}).xp, nil)
  for _, bad in ipairs({ "-3", "2.5", "viel", "100001" }) do
    local t = task({ { "xp", bad } })
    eq(t.xp, nil, bad)
    eq(t.error_codes, { "bad-xp" }, bad)
  end

  -- ── new and set ──
  local root = F.vault(H)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local made =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "C lernen", xp = 40 })))
  has(H.read(made.path), "\nxp: 40\n")
  eq(scan.find(made.id, { root = root }).xp, 40)
  has(
    select(2, mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Bad", xp = "-1" }))),
    "xp must be"
  )
  assert(mutate.set(made.id, { xp = "60" }, o))
  eq(scan.find(made.id, { root = root }).xp, 60)
  has(select(2, mutate.set(made.id, { xp = "1e3" }, o)), "xp must be a whole number")
  eq(scan.find(made.id, { root = root }).xp, 60, "a refused value changes nothing")
  assert(mutate.set(made.id, { xp = mutate.REMOVE }, o))
  eq(scan.find(made.id, { root = root }).xp, nil)
  ok(vim.tbl_contains(mutate.SETTABLE, "xp"))

  -- ── the command line ──
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
  local r = run({ "new", "lib.nvim", "Rust lernen", "--xp=80", "--no-index" })
  eq(r.code, 0, r.err)
  eq(scan.find("lib.nvim/rust-lernen", { root = root }).xp, 80)
  eq(run({ "set", "lib.nvim/rust-lernen", "xp=90", "--no-index" }).code, 0)
  eq(scan.find("lib.nvim/rust-lernen", { root = root }).xp, 90)

  -- ── promote takes the XP of the point along ──
  H.write(
    root .. "/lib.nvim/ROADMAP/paths/lua-lernen.md",
    table.concat({
      "---",
      "title: Lua lernen",
      "status: doing",
      "updated: " .. TODAY,
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [ ] C-Compiler erlernen {xp=35} {#cc}",
      "- [ ] Ohne XP {#plain}",
      "",
    }, "\n")
  )
  local cc = assert(promote.promote("lib.nvim/lua-lernen", "cc", o))
  eq(scan.find(cc.id, { root = root }).xp, 35)
  has(H.read(root .. "/lib.nvim/ROADMAP/paths/lua-lernen.md"), "{xp=35} {#cc}")
  local plain = assert(promote.promote("lib.nvim/lua-lernen", "plain", o))
  eq(scan.find(plain.id, { root = root }).xp, nil, "no XP on the point: none on the task")
end
