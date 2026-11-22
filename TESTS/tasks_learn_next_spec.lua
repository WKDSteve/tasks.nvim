-- TESTS/tasks_learn_next_spec.lua -- the next points of the running learning paths (`learn.next_points`,
-- `tasks.learn_next`, `tasks learn next`): open, not blocked, not optional, on the machine, in document order, `n` of
-- them; which paths run (doing; idle only with a begun project; never parked or waiting); their order; the refusals.
-- The document itself is the golden `learn-next`.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local G = dofile(here .. "/contract_golden.lua")
  local api = require("tasks_nvim.api")
  local cli = require("tasks_nvim.cli")
  local learn = require("tasks_nvim.learn")
  local lernbaum = require("tasks_nvim.lernbaum")

  -- ── pure: which points come next ───────────────────────────────────────────
  local tree = lernbaum.parse(table.concat({
    "## Lernpunkte",
    "",
    "- [ ] Stufe 1 {#s1}",
    "  - [x] Gelernt",
    "  - [!] Blockiert",
    "  - [~] Angeschaut – Grund: kurz",
    "  - [ ] Erst {#a}",
    "  - [?] Unbekannte Marke {#u}",
    "  - [ ] Nur privat {machine=private} {#p}",
    "  - [ ] Optional {optional}",
    "    - [ ] Darunter",
    "- [ ] Blatt als Stufe {#leaf}",
    "",
  }, "\n"))
  local function keys(points)
    return vim.tbl_map(function(n)
      return n.key or ("#" .. n.index)
    end, points)
  end
  eq(keys(learn.next_points(tree, { n = 10 })), { "a", "u", "p", "leaf" })
  eq(
    keys(learn.next_points(tree, { n = 10, machine = "workstation" })),
    { "a", "u", "leaf" },
    "a point for another machine is left out"
  )
  eq(keys(learn.next_points(tree)), { "a", "u", "p" }, "three by default")
  eq(keys(learn.next_points(tree, { n = 1 })), { "a" })
  eq(learn.stage_of(tree.by_key.a).key, "s1")
  eq(learn.stage_of(tree.by_key.leaf).key, "leaf", "a root is its own stage")
  eq(learn.next_points(lernbaum.parse("")), {})

  -- ── the document ──────────────────────────────────────────────────────────
  local root = F.vault(H)
  G.write_learn_paths(root)
  local function call(params)
    local text = api.call("learn_next", { params = params or {} }, { root = root, today = F.TODAY })
    local doc = vim.json.decode(text)
    return doc, doc.kind == "tasks.error" and doc.code or nil
  end
  local hello = vim.json.decode((api.call("hello", {}, { root = root })))
  ok(vim.tbl_contains(hello.capabilities, "learn_next"))

  local doc, code = call()
  eq(code, nil, vim.inspect(doc))
  eq(
    vim.tbl_map(function(i)
      return i.path .. ":" .. i.stage
    end, doc.items),
    { "lib.nvim/prozesse:doing", "lib.nvim/signale:idle" },
    "the running path first, the idle one of the begun project after it; no idle path without a project, no parked one"
  )
  eq(keys(doc.items[1].points), { "#5", "shell", "drv" }, "without a machine every machine counts")
  eq(doc.items[1].points[3].safety, true)
  eq(doc.items[1].points[3].machine, { "private" })
  eq(doc.machine, nil)

  -- the project not begun: its idle path is not running
  local proj = root .. "/lib.nvim/ROADMAP/projects/os.md"
  H.write(proj, (H.read(proj):gsub("status: doing", "status: planning")))
  local later = call()
  eq(#later.items, 1)
  ok(later.rev ~= doc.rev, "the project's status changes the rev")

  -- a point learned makes an idle path without status doing run (stage doing), newest first among the running
  local sp = root .. "/lib.nvim/ROADMAP/paths/spaeter.md"
  H.write(sp, (H.read(sp):gsub("%- %[ %] Irgendwann", "- [x] Gelernt\n- [ ] Irgendwann")))
  local run2 = call()
  eq(run2.items[1].path, "lib.nvim/spaeter", "updated 2026-01-06 comes before 2026-01-03")
  eq(run2.items[2].path, "lib.nvim/prozesse")

  -- a path with nothing left to learn is not listed
  H.write(sp, (H.read(sp):gsub("%- %[ %] Irgendwann", "- [x] Irgendwann")))
  eq(#call().items, 1)

  -- narrowed to paths and an area
  eq(
    #call({ paths = { "lib.nvim/signale" } }).items,
    0,
    "signale does not run while its project is not begun"
  )
  eq(#call({ paths = { "lib.nvim/prozesse" } }).items, 1)
  eq(#call({ area = "cascade.nvim" }).items, 0)

  -- the refusals
  eq(select(2, call({ n = 0 })), "invalid_argument")
  eq(select(2, call({ n = 21 })), "invalid_argument")
  eq(select(2, call({ machine = "laptop" })), "invalid_argument")
  eq(select(2, call({ area = "nope" })), "not_found")
  eq(select(2, call({ colour = "red" })), "invalid_argument")

  -- ── the command line ──────────────────────────────────────────────────────
  local function run(argv)
    local out, err = {}, {}
    vim.list_extend(argv, { "--vault=" .. root, "--today=" .. F.TODAY })
    local c = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return c, table.concat(out, "\n"), table.concat(err, "\n")
  end
  local c, out, err = run({ "learn", "next", "--machine=workstation", "--n=1" })
  eq(c, 0, err)
  eq(
    vim.trim(out),
    "lib.nvim/prozesse\t#5\tStufe 1 · Grundlagen\t[man fork](https://man7.org/linux/man-pages/man2/fork.2.html)\t-"
  )
  c, out = run({ "learn", "next", "--format=json" })
  eq(c, 0)
  eq(vim.json.decode(out).kind, "tasks.learn_next")
  eq((run({ "learn", "next", "--machine=laptop" })), 2)
  eq((run({ "learn", "next", "--format=xml" })), 2)
  eq((run({ "learn", "nope" })), 2)
  local c2, _, err2 = run({ "learn" })
  eq(c2, 2)
  has(err2, "usage: learn next")
end
