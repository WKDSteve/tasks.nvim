-- TESTS/tasks_close_by_hand_spec.lua -- finishing a plan or a project by hand in the editor (`:Tasks plan-close`,
-- `:Tasks project-close`, through the real command grammar) and the shared step `done_flow.close_by_hand`, which the
-- CLI's `plan-close` / `project-close` use too.

---@diagnostic disable: need-check-nil, duplicate-set-field
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local composer = require("lib.nvim.bindings.usercmd.composer")
  local routes = require("tasks_nvim.ui.routes")
  local confirm = require("tasks_nvim.ui.confirm")
  local done_flow = require("tasks_nvim.done_flow")
  local vault = require("tasks_nvim.vault")

  local root = F.vault(H)
  vault.set_root(root)
  routes.register_types()
  composer.verb("TaskC", { routes = routes.routes({ flat = true }) })
  local area = "lib.nvim"
  local function plan_file(slug, extra)
    H.write(
      ("%s/%s/ROADMAP/plans/%s.md"):format(root, area, slug),
      "---\ntitle: Plan "
        .. slug
        .. "\nstatus: doing\nareas: [lib.nvim]\nphase_order: []\n"
        .. (extra or "")
        .. "created: 2026-01-01\nupdated: 2026-01-01\n---\n\nA plan.\n"
    )
  end
  -- an empty plan (its tasks went elsewhere), a plan with an open task, a project that holds only the empty plan
  H.write(
    ("%s/%s/ROADMAP/projects/proj.md"):format(root, area),
    "---\ntitle: Project proj\nstatus: doing\nareas: [lib.nvim]\nphase_order: []\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nA project.\n"
  )
  plan_file("empty", "project: lib.nvim/proj\n")
  plan_file("busy")
  F.task(H, root, area, "holder", F.meta("Holder", "open", { { "plan", "lib.nvim/busy" } }))

  local orig_notify, orig_yesno = vim.notify, confirm.yesno
  local notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  local asked
  local answer = true
  confirm.yesno = function(msg, _, cb)
    asked = msg
    cb(answer)
  end
  local function run(line)
    notes, asked = {}, nil
    vim.cmd("TaskC " .. line)
    return table.concat(notes, "\n")
  end
  local function exists(rel)
    return vim.uv.fs_stat(root .. "/" .. rel) ~= nil
  end

  -- `check` names what does not finish by itself: a plan in `doing` without an open task, a project in `doing` with no
  -- open plan (a parked one does not count) and no task of its own; a plan in `planning` may be new, so it is not told
  ---@param kind "plans"|"projects"
  ---@param slug string
  ---@param head string   # the frontmatter lines between title and created
  local function file_of(kind, slug, head)
    H.write(
      ("%s/%s/ROADMAP/%s/%s.md"):format(root, area, kind, slug),
      table.concat({
        "---",
        "title: " .. slug,
        head,
        "created: 2026-01-01",
        "updated: 2026-01-01",
        "---",
        "",
        "x",
        "",
      }, "\n")
    )
  end
  file_of("plans", "fresh", "status: planning\nareas: [lib.nvim]\nphase_order: []")
  file_of("projects", "idle", "status: doing\nareas: [lib.nvim]\nphase_order: []")
  file_of(
    "plans",
    "resting",
    "status: parked\nareas: [lib.nvim]\nproject: lib.nvim/idle\nphase_order: []"
  )
  local function codes_of(id)
    local result = assert(require("tasks_nvim.check").run({ root = root }))
    local out = {}
    for _, f in ipairs(result.findings) do
      if f.id == id then
        out[#out + 1] = f.code
      end
    end
    table.sort(out)
    return out
  end

  local good, failure = pcall(function()
    ok(
      vim.tbl_contains(codes_of("lib.nvim/empty"), "plan-no-open-task"),
      "a plan in doing without an open task"
    )
    ok(
      not vim.tbl_contains(codes_of("lib.nvim/busy"), "plan-no-open-task"),
      "a plan with an open task"
    )
    ok(
      not vim.tbl_contains(codes_of("lib.nvim/fresh"), "plan-no-open-task"),
      "a new plan in planning"
    )
    ok(not vim.tbl_contains(codes_of("lib.nvim/resting"), "plan-no-open-task"), "a parked plan")
    ok(
      vim.tbl_contains(codes_of("lib.nvim/idle"), "project-no-open-work"),
      "a project with only a parked plan"
    )
    ok(
      not vim.tbl_contains(codes_of("lib.nvim/proj"), "project-no-open-work"),
      "a project with an open plan"
    )

    -- the shared step, as a dry run: nothing is written
    local dry = done_flow.close_by_hand("plan", "lib.nvim/empty", { root = root, dry_run = true })
    eq(dry.plans_closed, { "lib.nvim/empty" })
    ok(exists(area .. "/ROADMAP/plans/empty.md"), "a dry run writes nothing")
    local held = done_flow.close_by_hand("plan", "lib.nvim/busy", { root = root, dry_run = true })
    eq(held.holding, { "lib.nvim/holder" })
    local gone = done_flow.close_by_hand("plan", "lib.nvim/nope", { root = root })
    ok(gone.err, "no such plan")

    -- a plan with an open task: refused, nothing asked
    local text = run("plan-close lib.nvim/busy")
    eq(asked, nil, "a refusal asks nothing")
    has(text, "lib.nvim/busy still has 1 open task: lib.nvim/holder")
    ok(exists(area .. "/ROADMAP/plans/busy.md"))

    -- asked first; a No keeps it
    answer = false
    text = run("plan-close lib.nvim/empty")
    has(asked, "Finish plan lib.nvim/empty by hand?")
    has(asked, "Plan empty")
    has(text, "cancelled -- the plan stays open")
    ok(exists(area .. "/ROADMAP/plans/empty.md"))

    -- a Yes finishes the plan, and the project it was the last open plan of
    answer = true
    text = run("plan-close lib.nvim/empty")
    has(text, "Plan lib.nvim/empty is done")
    has(text, "Project lib.nvim/proj is done")
    ok(not exists(area .. "/ROADMAP/plans/empty.md"), "the plan file left ROADMAP")
    ok(not exists(area .. "/ROADMAP/projects/proj.md"), "the project went with it")

    -- again: already finished, no question
    text = run("plan-close lib.nvim/empty")
    eq(asked, nil)
    has(text, "lib.nvim/empty is already finished")

    -- a project by hand, --yes skips the question
    H.write(
      ("%s/%s/ROADMAP/projects/alone.md"):format(root, area),
      "---\ntitle: Project alone\nstatus: doing\nareas: [lib.nvim]\nphase_order: []\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nNothing in it.\n"
    )
    text = run("project-close lib.nvim/alone --yes")
    eq(asked, nil, "--yes asks nothing")
    has(text, "Project lib.nvim/alone is done")
  end)
  vim.notify = orig_notify
  confirm.yesno = orig_yesno
  vault.set_root(nil)
  if not good then
    error(failure, 0)
  end
end
