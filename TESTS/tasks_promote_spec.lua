-- TESTS/tasks_promote_spec.lua -- promoting a learning point to a task (`tasks_nvim.promote`): the subtree moves into
-- the task, the point gets the arrow, the recursion over three levels (Lua lernen -> C-Compiler -> Sprache C), the state
-- a finished task writes back after its outcome, the parent rule, `unpromote`, the `check` findings and the CLI.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local cli = require("tasks_nvim.cli")
  local done_flow = require("tasks_nvim.done_flow")
  local lernbaum = require("tasks_nvim.lernbaum")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local paths = require("tasks_nvim.paths")
  local promote = require("tasks_nvim.promote")
  local scan = require("tasks_nvim.scan")

  local TODAY = "2026-11-19"
  local ARROW = "\226\134\146"

  -- ── pure parts ────────────────────────────────────────────────────────────
  eq({ model.parse_point("lib.nvim/lua-lernen#cc") }, { "lib.nvim/lua-lernen", "cc" })
  eq(model.parse_point("lib.nvim/lua-lernen"), nil, "a point names its key")
  eq(model.parse_point("lua-lernen#cc"), nil, "and its container as <area>/<slug>")
  eq(lernbaum.state_of_task({ status = "open" }), "open")
  eq(lernbaum.state_of_task({ status = "blocked" }), "blocked")
  eq(lernbaum.state_of_task({ status = "done" }), "learned", "no outcome: done as meant")
  eq(lernbaum.state_of_task({ status = "done", outcome = "seen" }), "seen")
  eq(lernbaum.state_of_task({ status = "done", outcome = "not-applicable" }), "dropped")
  eq(
    promote.plain_label("[Lua 5.4 Manual](https://x) ![i](assets/a.png) `code`"),
    "Lua 5.4 Manual code"
  )

  -- ── the path ──────────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local path_file = root .. "/lib.nvim/ROADMAP/paths/lua-lernen.md"
  local original = table.concat({
    "---",
    "title: Lua lernen",
    "status: doing",
    "updated: " .. TODAY,
    "---",
    "",
    "Warum: Plugins schreiben.",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Lua lernen {#lua}",
    "  - [x] [Manual](https://www.lua.org/manual/5.4/)",
    "  - [ ] C-Compiler erlernen {#cc}",
    "    > Notiz: erst gcc, dann clang.",
    "    - [ ] Sprache C {#c}",
    "      - [ ] K&R lesen",
    "      - [~] Online-Kurs – Grund: zu lang",
    "    - [ ] gcc bedienen",
    "  - [-] JIT – Grund: nicht nötig",
    "",
    "## Notizen",
    "",
    "Text danach.",
    "",
  }, "\n")
  H.write(path_file, original)

  -- a dry run names the task and writes nothing
  local dry = assert(
    promote.promote("lib.nvim/lua-lernen", "cc", vim.tbl_extend("force", o, { dry_run = true }))
  )
  eq(dry.id, "lib.nvim/c-compiler-erlernen")
  eq(dry.moved, 4, "the subtree: Sprache C with its two points, and gcc bedienen")
  eq(dry.inverse, { op = "unpromote", container = "lib.nvim/lua-lernen", key = "cc" })
  eq(H.read(path_file), original, "a dry run writes nothing")
  eq(scan.find(dry.id, { root = root }), nil)

  local cc = assert(promote.promote("lib.nvim/lua-lernen", "cc", o))
  eq(cc.id, "lib.nvim/c-compiler-erlernen")
  local ptext = H.read(path_file)
  has(ptext, "  - [ ] C-Compiler erlernen " .. ARROW .. " lib.nvim/c-compiler-erlernen {#cc}\n")
  has(ptext, "    > Notiz: erst gcc, dann clang.\n  - [-] JIT", "the note stays with the point")
  lacks(ptext, "Sprache C", "the subtree left the path")
  has(ptext, "## Notizen\n\nText danach.\n", "the rest of the file as it was")
  local cct = H.read(cc.path)
  has(cct, "point: lib.nvim/lua-lernen#cc\n")
  has(cct, "category: [learning]\n")
  has(cct, "kind: task\n")
  has(
    cct,
    "\n## Lernpunkte\n\n- [ ] Sprache C {#c}\n  - [ ] K&R lesen\n  - [~] Online-Kurs – Grund: zu lang\n- [ ] gcc bedienen\n"
  )
  has(cct, "Befördert aus dem Lernpunkt `{#cc}` von `lib.nvim/lua-lernen`.")
  has(cct, "> Notiz: erst gcc, dann clang.", "the note is copied into the task's context")
  eq(scan.find(cc.id, { root = root }).point, "lib.nvim/lua-lernen#cc")

  -- refused: promoted already, a closed leaf, no such point
  has(select(2, promote.promote("lib.nvim/lua-lernen", "cc", o)), "was promoted already")
  has(select(2, promote.promote("lib.nvim/lua-lernen", "#2", o)), "is closed already")
  has(select(2, promote.promote("lib.nvim/lua-lernen", "nope", o)), "no learning point nope")
  has(select(2, promote.promote("lib.nvim/nothing", "cc", o)), "no open learning path or task")

  -- the parent rule: the path's root is not closed while the promoted point is open
  local tree = assert(paths.find("lib.nvim/lua-lernen", { root = root })).tree
  ok(not tree.by_key.lua.closed, "Lua lernen is open while C-Compiler is")
  eq(tree.by_key.cc.state, "open")

  -- ── the recursion: a point of the task's own tree ─────────────────────────
  local c = assert(promote.promote(cc.id, "c", o))
  eq(c.id, "lib.nvim/sprache-c")
  has(
    H.read(cc.path),
    "- [ ] Sprache C " .. ARROW .. " lib.nvim/sprache-c {#c}\n- [ ] gcc bedienen"
  )
  has(H.read(c.path), "point: lib.nvim/c-compiler-erlernen#c\n")
  has(H.read(c.path), "## Lernpunkte\n\n- [ ] K&R lesen\n- [~] Online-Kurs – Grund: zu lang\n")

  -- a point without a key gets one
  local gcc = assert(promote.promote(cc.id, "#2", vim.tbl_extend("force", o, { dry_run = true })))
  eq(gcc.key, "gcc-bedienen")

  -- a point promoted below a point that moves: its task follows to the new container (and back)
  local deep_path = root .. "/lib.nvim/ROADMAP/paths/deep.md"
  H.write(
    deep_path,
    table.concat({
      "---",
      "title: Deep",
      "status: doing",
      "updated: " .. TODAY,
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [ ] Oben {#oben}",
      "  - [ ] Unten {#unten}",
      "",
    }, "\n")
  )
  local unten = assert(promote.promote("lib.nvim/deep", "unten", o))
  eq(scan.find(unten.id, { root = root }).point, "lib.nvim/deep#unten")
  local oben = assert(promote.promote("lib.nvim/deep", "oben", o))
  eq(oben.repointed, { unten.id })
  eq(
    scan.find(unten.id, { root = root }).point,
    oben.id .. "#unten",
    "the inner task follows its point"
  )
  assert(promote.unpromote("lib.nvim/deep", "oben", o))
  eq(scan.find(unten.id, { root = root }).point, "lib.nvim/deep#unten", "and comes back with it")

  -- ── done writes the state back ────────────────────────────────────────────
  local flow = assert(
    done_flow.run(
      c.id,
      vim.tbl_extend(
        "force",
        o,
        { outcome = "seen", outcome_reason = "nur Grundlagen", pick_next = false }
      )
    )
  )
  eq(flow.point, { container = cc.id, key = "c", state = "seen", changed = true })
  has(flow.notes[1] or "", "1 open learning point", "K&R is still open: a warning, not a refusal")
  has(
    H.read(cc.path),
    "- [~] Sprache C " .. ARROW .. " lib.nvim/sprache-c – Grund: nur Grundlagen {#c}\n"
  )

  -- tick_all ticks `## Plan`, never the learning points
  local cflow = assert(done_flow.run(cc.id, vim.tbl_extend("force", o, { pick_next = false })))
  eq(cflow.point.state, "learned")
  local cfin = assert(scan.find_done(cc.id, { root = root }))
  has(H.read(cfin.path), "- [ ] gcc bedienen", "finishing leaves the learning points as they are")
  has(cflow.notes[1] or "", "open learning point")
  local after = assert(paths.find("lib.nvim/lua-lernen", { root = root })).tree
  eq(after.by_key.cc.state, "learned")
  ok(after.by_key.lua.closed, "every leaf of Lua lernen is closed now")
  eq(after.by_key.lua.derived, "partial", "learned and dropped: partial")

  -- ── unpromote ─────────────────────────────────────────────────────────────
  local p2 = root .. "/lib.nvim/ROADMAP/paths/rust.md"
  local p2_text = table.concat({
    "---",
    "title: Rust",
    "status: doing",
    "updated: " .. TODAY,
    "---",
    "",
    "## Lernpunkte",
    "",
    "- [ ] Ownership {#own}",
    "  > Kapitel 4.",
    "  - [ ] Borrowing",
    "  - [x] Moves",
    "- [ ] Traits",
    "",
  }, "\n")
  H.write(p2, p2_text)
  local own = assert(promote.promote("lib.nvim/rust", "own", o))
  local back_dry = assert(
    promote.unpromote("lib.nvim/rust", "own", vim.tbl_extend("force", o, { dry_run = true }))
  )
  eq(back_dry.id, own.id)
  ok(scan.find(own.id, { root = root }), "a dry run keeps the task")
  assert(mutate.set(own.id, { status = "doing" }, o))
  has(select(2, promote.unpromote("lib.nvim/rust", "own", o)), "is doing: it holds work of its own")
  assert(mutate.set(own.id, { status = "open" }, o))
  assert(promote.unpromote("lib.nvim/rust", "own", o))
  eq(H.read(p2), p2_text, "the way back gives the path byte for byte")
  eq(scan.find(own.id, { root = root }), nil, "the task is gone")

  -- ── check ─────────────────────────────────────────────────────────────────
  F.task(
    H,
    root,
    "lib.nvim",
    "astray",
    F.meta("Astray", "open", { { "point", "lib.nvim/lua-lernen#nope" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "ring-a",
    F.meta("Ring A", "open", { { "point", "lib.nvim/ring-b#x" } })
  )
  F.task(
    H,
    root,
    "lib.nvim",
    "ring-b",
    F.meta("Ring B", "open", { { "point", "lib.nvim/ring-a#y" } })
  )
  local early = assert(promote.promote("lib.nvim/rust", "#4", o))
  -- the mark runs ahead of the open task
  H.write(p2, (H.read(p2):gsub("%- %[ %] Traits", "- [x] Traits")))
  F.task(
    H,
    root,
    "lib.nvim",
    "lern-mich",
    F.meta("Lern mich", "open", { { "category", "[learning]" } }),
    "\n## Lernpunkte\n\n- [ ] Weg " .. ARROW .. " lib.nvim/gibt-es-nicht\n"
  )
  local r = assert(check.run({ root = root, area = "lib.nvim", today = TODAY }))
  local got = {}
  for _, f in ipairs(r.findings) do
    if f.code:find("^promote%-") or f.code == "task-arrow-dangling" then
      got[#got + 1] = f.code .. ":" .. f.id
    end
  end
  table.sort(got)
  ok(vim.tbl_contains(got, "promote-point-dangling:lib.nvim/astray"), vim.inspect(got))
  ok(vim.tbl_contains(got, "promote-state-drift:" .. early.id), vim.inspect(got))
  ok(
    vim.tbl_contains(got, "promote-cycle:lib.nvim/ring-a")
      or vim.tbl_contains(got, "promote-cycle:lib.nvim/ring-b"),
    vim.inspect(got)
  )
  ok(vim.tbl_contains(got, "task-arrow-dangling:lib.nvim/lern-mich"), vim.inspect(got))
  for _, f in ipairs(r.findings) do
    if f.code:find("^promote%-") then
      eq(f.severity, "warn", "never an error (R3)")
    end
  end
  ok(
    not vim.tbl_contains(got, "promote-point-dangling:" .. c.id),
    "a finished task whose point is right: no finding"
  )

  -- ── the command line ──────────────────────────────────────────────────────
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
  local wd = run({ "promote", "lib.nvim/rust#own", "--dry-run" })
  eq(wd.code, 0, wd.err)
  has(wd.out, "would-promote\tlib.nvim/rust#own\tlib.nvim/ownership\t2 line(s) moved")
  local pr = run({ "promote", "lib.nvim/rust#own", "--title=Ownership verstehen" })
  eq(pr.code, 0, pr.err)
  has(pr.out, "promoted\tlib.nvim/rust#own\tlib.nvim/ownership-verstehen")
  local up = run({ "unpromote", "lib.nvim/rust#own" })
  eq(up.code, 0, up.err)
  has(up.out, "unpromoted\tlib.nvim/rust#own\tlib.nvim/ownership-verstehen")
  eq(run({ "promote", "lib.nvim/rust" }).code, 2, "the point needs #<key>")
end
