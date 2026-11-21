-- TESTS/tasks_reopen_cli_spec.lua -- `tasks reopen`: a finished task back to ROADMAP/tasks from the command line,
-- through the write door. The id as `show` takes it and the name of the finished file; the README row and the index;
-- an open task stays (exit 0); a folder task, an unknown id and a wrong status are refused.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local mutate = require("tasks_nvim.mutate")
  local scan = require("tasks_nvim.scan")

  local TODAY = F.TODAY
  local AREA = "lib.nvim"

  -- ── the id: as show takes it, or the name of the finished file ────────────
  eq(cli.reopen_id("a/slug"), "a/slug")
  eq(cli.reopen_id("a/2026-11-18_slug"), "a/slug", "the date of the finished file goes")
  eq(cli.reopen_id("a/2026-11-18_slug.md"), "a/slug", "and the extension")
  eq(cli.reopen_id("a/Backlog/TASKS/2026-11-18_slug.md"), "a/slug", "a path below the vault")
  eq(cli.reopen_id("a\\Backlog\\FEATURES\\2026-11-18_slug.md"), "a/slug", "with backslashes")
  eq(cli.reopen_id("noslash"), "noslash", "what is no id stays for the engine to refuse")

  local root = F.vault(H)
  local o = { root = root, today = TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
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
  local function finished(title)
    local t = assert(mutate.new(AREA, vim.tbl_extend("force", o, { title = title })))
    local r = run({ "done", t.id, "--commits=lib.nvim@abc1234", "--no-next" })
    eq(r.code, 0, r.err)
    return t.id, assert(scan.find_done(t.id, { root = root })).path
  end
  local readme = root .. "/" .. AREA .. "/Backlog/README.md"
  local index_file = root .. "/" .. AREA .. "/ROADMAP/TASKS.md"

  -- ── reopen: the file, the README row, the index ───────────────────────────
  local id, done_path = finished("Brought back")
  local done_name = done_path:match("([^/\\]+)$")
  has(H.read(readme), done_name, "the finish wrote its row")
  lacks(H.read(index_file), "Brought back", "a finished task is not in the overview")
  local r = run({ "reopen", id })
  eq(r.code, 0, r.err)
  has(
    r.out,
    "reopened\t" .. id .. "\t" .. AREA .. "/ROADMAP/tasks/",
    "the new place, relative to the vault"
  )
  has(r.out, "index\t", "the overview was written")
  ok(scan.find_done(id, { root = root }) == nil, "the finished file is gone")
  local open_text = H.read(root .. "/" .. AREA .. "/ROADMAP/tasks/" .. id:match("/(.+)$") .. ".md")
  has(open_text, "status: open")
  lacks(open_text, "done_in:", "done_in goes")
  lacks(H.read(readme), done_name, "the row of the README goes")
  has(H.read(index_file), "Brought back", "the overview lists it again")

  -- ── open already: a hint, exit 0, nothing written ─────────────────────────
  local before = open_text
  r = run({ "reopen", id })
  eq(r.code, 0, r.err)
  has(r.out, "already-open\t" .. id)
  eq(H.read(root .. "/" .. AREA .. "/ROADMAP/tasks/" .. id:match("/(.+)$") .. ".md"), before)

  -- ── by the name of the finished file, with a status ───────────────────────
  local id2, done2 = finished("Back as blocked")
  r = run({ "reopen", AREA .. "/" .. done2:match("([^/\\]+)$"), "--status=blocked" })
  eq(r.code, 0, r.err)
  has(r.out, "reopened\t" .. id2)
  has(
    H.read(root .. "/" .. AREA .. "/ROADMAP/tasks/" .. id2:match("/(.+)$") .. ".md"),
    "status: blocked"
  )

  -- ── refused ───────────────────────────────────────────────────────────────
  r = run({ "reopen", AREA .. "/never-was" })
  eq(r.code, 1)
  has(r.err, "no such finished task: " .. AREA .. "/never-was")
  r = run({ "reopen", id2, "--status=done" })
  eq(r.code, 2, "done is no status to come back with")
  has(r.err, "unknown status 'done'")
  r = run({ "reopen" })
  eq(r.code, 2)
  has(r.err, "usage: reopen")
  r = run({ "reopen", "a/b", "c/d" })
  eq(r.code, 2, "one id only")

  -- a folder task is not moved: the engine says so, the CLI exits 1
  local folder =
    assert(mutate.new(AREA, vim.tbl_extend("force", o, { title = "Folder one", folder = true })))
  r = run({ "done", folder.id, "--no-next" })
  eq(r.code, 0, r.err)
  r = run({ "reopen", folder.id })
  eq(r.code, 1)
  has(r.err, "is a folder task")
  ok(scan.find_done(folder.id, { root = root }) ~= nil, "the folder stays finished")

  -- ── :Tasks reopen: asks first, completes over the finished tasks only ─────
  local cmd = require("tasks_nvim.ui.cmd")
  local routes = require("tasks_nvim.ui.routes")
  require("tasks_nvim.vault").set_root(root)
  local told = {}
  local orig_notify = vim.notify
  vim.notify = function(msg)
    told[#told + 1] = msg
  end
  local ran, rerr = pcall(function()
    local id3, done3 = finished("Back in the editor")
    local asked
    local function ctx(kv, flags)
      return { args = { id = id3 }, kv = kv or {}, flags = flags or {}, rest = {} }
    end
    -- no: nothing moves
    cmd.task_reopen(ctx(), function(msg, label, cb)
      asked = { msg = msg, label = label }
      cb(false)
    end)
    has(asked.msg, "Bring task " .. id3 .. " back?")
    has(asked.msg, "Back in the editor")
    eq(asked.label, "reopen")
    ok(H.exists(done3), "declined: the finished file stays")
    has(told[#told], "stays finished")
    -- yes, as doing
    cmd.task_reopen(ctx({ status = "doing" }), function(_, _, cb)
      cb(true)
    end)
    ok(not H.exists(done3), "the finished file is gone")
    has(told[#told], "reopened " .. id3)
    has(
      H.read(root .. "/" .. AREA .. "/ROADMAP/tasks/" .. id3:match("/(.+)$") .. ".md"),
      "status: doing"
    )
    -- open now: named, no question
    asked = nil
    cmd.task_reopen(ctx(), function()
      asked = true
    end)
    ok(asked == nil, "an open task is not asked about")
    has(told[#told], "is open already")
    -- a wrong status is refused before anything is asked
    cmd.task_reopen(ctx({ status = "done" }), function()
      asked = true
    end)
    ok(asked == nil)
    has(told[#told], "unknown status 'done'")

    -- the route takes a finished id and completes over the finished ones only
    local route
    for _, each in ipairs(routes.routes({ flat = true })) do
      if each.path[1] == "reopen" then
        route = each
      end
    end
    ok(route, "the route reopen exists")
    routes.register_types()
    routes.reset_complete_cache()
    local spec = route.args[1]
    local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
    local candidates = argtypes.get("TASK_ID").complete("", spec)
    ok(vim.tbl_contains(candidates, id2) == false, "an open task is not offered")
    ok(vim.tbl_contains(candidates, folder.id), "a finished one is")
  end)
  vim.notify = orig_notify
  ok(ran, tostring(rerr))

  -- the help names the command
  r = run({ "--help" })
  has(r.out, "reopen <area>/<slug> [--status=")
end
