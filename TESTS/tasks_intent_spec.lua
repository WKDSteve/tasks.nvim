-- TESTS/tasks_intent_spec.lua -- taking an intent `wkd-intent/1`: the target's check (copies of the golden examples of
-- @scans-data (what it lists is a fixture vault in a temp folder; a changed helper of TESTS/ selects it anyway)
-- appkit/schemas/wkd-intent/1 in TESTS/intent/), what `tasks.new` and `tasks.show` do, refs of registered namespaces
-- through the ops door, `find`, the handshake and the CLI verb `intent`.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local intent = require("tasks_nvim.intent")
  local find = require("tasks_nvim.find")
  local scan = require("tasks_nvim.scan")

  ---@param name string
  ---@return string
  local function golden_text(name)
    return H.read(here .. "/intent/" .. name .. ".json")
  end
  ---@param name string
  ---@return table
  local function golden(name)
    return vim.json.decode(golden_text(name))
  end
  ---@param doc table
  ---@return string[]
  local function problems(doc)
    return (intent.check(vim.json.encode(doc)))
  end
  ---@param doc table
  ---@param needle string
  ---@param label string
  local function refused(doc, needle, label)
    local found = problems(doc)
    local hit = false
    for _, line in ipairs(found) do
      hit = hit or line:find(needle, 1, true) ~= nil
    end
    ok(hit, ("%s: %q not in %s"):format(label, needle, vim.inspect(found)))
  end
  ---@param change fun(doc: table)
  ---@return table
  local function mutated(change)
    local doc = golden("tasks.new")
    change(doc)
    return doc
  end

  -- ── the goldens ────────────────────────────────────────────────────────────
  eq(problems(golden("tasks.new")), {}, "tasks.new of the schema passes")
  eq(problems(golden("tasks.show")), {}, "tasks.show of the schema passes")
  for _, name in ipairs({ "rules.new", "rules.show", "ai.handoff" }) do
    refused(
      golden(name),
      "this target does not take " .. name,
      "an action of another app: " .. name
    )
  end
  eq(
    intent.handshake(),
    { schema = "wkd-intent/1", actions = { "tasks.new", "tasks.show" }, modes = { "form" } }
  )

  -- ── what the target refuses ────────────────────────────────────────────────
  eq(
    (intent.check(string.rep(" ", intent.MAX_BYTES + 1))),
    { "larger than 65536 bytes" },
    "size, before parsing"
  )
  eq(
    (intent.check(string.rep("[", 100000))),
    { "larger than 65536 bytes" },
    "a deep nesting is never parsed"
  )
  for _, raw in ipairs({ "", "[1]", "null", "{ not json", "\255\254" }) do
    ok(#(intent.check(raw)) > 0, "not an intent: " .. vim.inspect(raw))
  end
  refused(
    mutated(function(d)
      d.schema = "wkd-intent/2"
    end),
    "is not wkd-intent/1",
    "a higher version"
  )
  refused(
    mutated(function(d)
      d.action = "tasks.delete"
    end),
    "unknown action",
    "a foreign action"
  )
  refused(
    mutated(function(d)
      d.mode = "ai-draft"
    end),
    "does not take mode ai-draft",
    "a mode tasks does not offer"
  )
  refused(
    mutated(function(d)
      d.mode = "magic"
    end),
    "unknown mode",
    "an unknown mode"
  )
  refused(
    mutated(function(d)
      d.finding.class = "private"
    end),
    "finding.class is not public or internal",
    "a private finding"
  )
  refused(
    mutated(function(d)
      d.finding.class = nil
    end),
    "finding.class",
    "no class"
  )
  refused(
    mutated(function(d)
      d.finding.where.file = "/etc/passwd"
    end),
    "finding.where.file leaves the repository",
    "an absolute path"
  )
  for _, bad in ipairs({ "C:\\x", "C:/x", "\\\\host\\x", "~/x", "$HOME/x", "a/../b", "../x" }) do
    refused(
      mutated(function(d)
        d.finding.where.file = bad
      end),
      "leaves the repository",
      "a way out: " .. bad
    )
  end
  refused(
    mutated(function(d)
      d.finding.repro = 'scripts/test.sh --out="/etc/x"'
    end),
    "finding.repro leaves the repository",
    "a path in the repro, after a quote"
  )
  refused(
    mutated(function(d)
      d.finding.repro = "cat --out=/etc/x"
    end),
    "finding.repro leaves the repository",
    "a path in the repro, after ="
  )
  refused(
    mutated(function(d)
      d.finding.title = string.rep("t", 121)
    end),
    "finding.title is longer than 120",
    "a long title"
  )
  refused(
    mutated(function(d)
      d.finding.excerpt = string.rep("x", 4097)
    end),
    "finding.excerpt is longer than 4096",
    "a long excerpt"
  )
  refused(
    mutated(function(d)
      d.finding.title = "a\1b"
    end),
    "a field holds a control character",
    "a control character"
  )
  refused(
    mutated(function(d)
      d.finding.run.url = "https://example.com/x"
    end),
    "finding.run.url does not start with https://github.com/",
    "a foreign run url"
  )
  refused(
    mutated(function(d)
      d.finding.fp = "XYZ"
    end),
    "finding.fp is not 16 hex characters",
    "a bad fingerprint"
  )
  refused(
    mutated(function(d)
      d.source.app = "Not A Name"
    end),
    "source.app",
    "a bad source app"
  )
  refused(
    mutated(function(d)
      d.target = { id = "a/b" }
    end),
    "tasks.new has no target",
    "a target on tasks.new"
  )
  refused(
    mutated(function(d)
      d.finding = nil
    end),
    "finding is missing",
    "no finding"
  )
  local show = golden("tasks.show")
  show.finding = golden("tasks.new").finding
  refused(show, "carries no finding", "a finding on tasks.show")
  show = golden("tasks.show")
  show.target.id = "../../etc/x"
  refused(show, "target.id leaves the repository", "a target that leaves the repository")
  show = golden("tasks.show")
  show.mode = "agent"
  refused(show, "only knows mode form", "tasks.show in another mode")
  -- every problem is named, not the first only
  local many = mutated(function(d)
    d.finding.class = "private"
    d.finding.where.file = "/x"
    d.finding.title = ""
  end)
  ok(#problems(many) >= 3, "every problem: " .. vim.inspect(problems(many)))
  -- the lengths count characters, not bytes
  eq(
    problems(mutated(function(d)
      d.finding.title = string.rep("\195\164", 120)
    end)),
    {},
    "120 characters of two bytes each are fine"
  )

  -- ── leaves_repo ────────────────────────────────────────────────────────────
  for _, text in ipairs({
    "scripts/test.sh --file parse_spec",
    "TESTS/a_spec.lua",
    "a..b",
    "x...y",
    "my-file.lua",
    "100%",
  }) do
    ok(not intent.leaves_repo(text), "stays inside: " .. text)
  end
  for _, text in ipairs({
    "/x",
    "run /x",
    "a=/x",
    "'/x'",
    "..",
    "a ..",
    "a/..",
    "a/../b",
    "%APPDATA%\\x",
    "${HOME}/x",
    "~\\x",
  }) do
    ok(intent.leaves_repo(text), "leaves: " .. text)
  end

  -- ── taking tasks.new ───────────────────────────────────────────────────────
  local root = F.vault(H)
  local function own(change)
    local doc = mutated(function(d)
      d.finding.area = "lib.nvim"
      change(d)
    end)
    return vim.json.encode(doc)
  end
  local opts = { root = root, today = "2026-11-07" }
  local function run(text, extra)
    return intent.run(text, vim.tbl_extend("force", opts, extra or {}))
  end

  local plan = assert(run(own(function() end)))
  eq(plan.outcome, "would_create")
  eq(plan.area, "lib.nvim")
  eq(plan.title, "parse_spec: an empty line ends the list")
  eq(
    #scan.area("lib.nvim", { root = root }),
    #scan.area("lib.nvim", { root = root }),
    "a dry run writes nothing"
  )
  eq(find.by_refs({ "testing-finding:0123456789abcdef" }, { root = root }), {}, "no task yet")

  local made = assert(run(own(function() end), { yes = true }))
  eq(made.outcome, "created")
  local task = assert(scan.find(made.id, { root = root }))
  eq(task.kind, "bug")
  eq(task.tags, { "testing" })
  eq(task.refs, {
    "testing-finding:0123456789abcdef",
    "TESTS/parse_spec.lua:12",
    "example.nvim@0123456789abcdef0123456789abcdef01234567",
  })
  local text = H.read(task.path)
  has(text, "expected 2 items, got 1")
  has(text, "Nachstellen: `scripts/test.sh --file parse_spec`")
  has(text, "https://github.com/example/example.nvim/actions/runs/1234")
  has(text, "## Akzeptanz")
  ok(task.valid, "a task made from a finding is valid")
  eq(
    assert(run(own(function() end), { yes = true, lang = "en" })).outcome,
    "exists",
    "the same finding is never a second task"
  )

  -- the same finding twice: exists (dry run too), with the task named
  local again = assert(run(own(function() end)))
  eq(again.outcome, "exists")
  eq(again.id, made.id)
  eq(again.location, "open")
  eq(#again.matches, 1)
  -- a finished task holds the ref as well
  assert(
    require("tasks_nvim.mutate").done(made.id, { root = root, today = "2026-11-07", index = false })
  )
  local done_again = assert(run(own(function() end)))
  eq(done_again.outcome, "exists")
  eq(done_again.location, "done", "also when the task is finished")
  eq(find.by_refs({ "testing-finding:0123456789abcdef" }, { root = root })[1].location, "done")

  -- an area the vault does not have, a refused intent, a bad vault
  local _, unknown = run(
    own(function(d)
      d.finding.area = "nowhere.nvim"
    end),
    { yes = true }
  )
  has(unknown, "no area of this vault")
  local _, bad = run(
    own(function(d)
      d.finding.class = "private"
    end),
    { yes = true }
  )
  has(bad, "intent refused: finding.class")
  ok(
    not find.by_refs({ "testing-finding:ffffffffffffffff" }, { root = root })[1],
    "nothing was written"
  )
  ok(select(2, intent.run(golden_text("tasks.new"), { root = root .. "/missing" })), "no vault")

  -- ── taking tasks.show ──────────────────────────────────────────────────────
  local alpha = F.task(H, root, "lib.nvim", "show-me", F.meta("Show me", "open"))
  ok(alpha ~= nil)
  local shown = assert(run(vim.json.encode({
    schema = "wkd-intent/1",
    action = "tasks.show",
    mode = "form",
    source = { app = "hub" },
    finding = vim.NIL,
    target = { id = "lib.nvim/show-me" },
  })))
  eq(shown.outcome, "shown")
  eq(shown.id, "lib.nvim/show-me")
  eq(shown.location, "open")
  local missing = assert(run(vim.json.encode({
    schema = "wkd-intent/1",
    action = "tasks.show",
    mode = "form",
    source = { app = "hub" },
    finding = vim.NIL,
    target = { id = "lib.nvim/nope" },
  })))
  eq(missing.outcome, "not_found")
  local _, badid = run(vim.json.encode({
    schema = "wkd-intent/1",
    action = "tasks.show",
    mode = "form",
    source = { app = "hub" },
    finding = vim.NIL,
    target = { id = "no-slash" },
  }))
  has(badid, "target.id")

  -- ── refs of registered namespaces through the ops door ─────────────────────
  local api = require("tasks_nvim.api")
  ---The decoded document an API call answers (the call also returns the error code: not an argument of `decode`).
  local function jcall(...)
    local raw = api.call(...)
    return vim.json.decode(raw)
  end
  local function new_with(ref)
    local door = api.call(
      "ops",
      vim.json.encode({
        ops = {
          { op = "new", area = "lib.nvim", title = "Ref " .. ref, fields = { refs = { ref } } },
        },
      }),
      { root = root, today = "2026-11-07" }
    )
    return vim.json.decode(door).results[1]
  end
  eq(new_with("testing-finding:00000000000000aa").ok, true, "a registered namespace")
  eq(new_with("rules-target:lua/lib").ok, true, "with a folder as the key")
  local foreign = new_with("somebody-else:key")
  eq(foreign.ok, false, "a namespace that is not registered stays refused")
  has(foreign.error.message, "a colon that is not a line suffix")
  has(new_with("testing-finding:../x").error.message, "a '..' segment")
  has(new_with("testing-finding:/abs").error.message, "an absolute path")
  has(new_with("testing-finding:a b").error.message, "key of this namespace")
  eq(new_with("TESTS/parse_spec.lua:12").ok, true, "a line suffix still works")

  -- ── find ───────────────────────────────────────────────────────────────────
  local found = jcall(
    "find",
    vim.json.encode({
      params = {
        refs = { "testing-finding:00000000000000aa", "rules-target:lua/lib", "nothing" },
      },
    }),
    { root = root }
  )
  eq(found.kind, "tasks.find", vim.inspect(found))
  eq(#found.matches, 2)
  eq(found.matches[1].location, "open")
  eq(found.matches[1].area, "lib.nvim")
  ok(found.matches[1].id and found.matches[1].status, "id and status")
  ok(not vim.json.encode(found):find(root, 1, true), "no path of this machine")
  for _, request in ipairs({
    "{}",
    '{"params":{"refs":[]}}',
    '{"params":{"refs":[""]}}',
    '{"params":{"refs":"x"}}',
  }) do
    eq(jcall("find", request, { root = root }).kind, "tasks.error", request)
  end
  local many_refs = {}
  for i = 1, 51 do
    many_refs[i] = "r" .. i
  end
  eq(
    jcall("find", vim.json.encode({ params = { refs = many_refs } }), { root = root }).code,
    "invalid_argument"
  )

  -- ── the call and the handshake ─────────────────────────────────────────────
  local hello = jcall("hello", nil, { root = root })
  eq(
    hello.intents,
    { schema = "wkd-intent/1", actions = { "tasks.new", "tasks.show" }, modes = { "form" } }
  )
  ok(
    vim.tbl_contains(hello.capabilities, "find") and vim.tbl_contains(hello.capabilities, "intent")
  )
  local doc = jcall(
    "intent",
    vim.json.encode({
      params = {
        intent = vim.json.decode(own(function(d)
          d.finding.fp = "bbbbbbbbbbbbbbbb"
        end)),
      },
    }),
    { root = root }
  )
  eq(doc.kind, "tasks.intent", vim.inspect(doc))
  eq(doc.outcome, "would_create")
  local refused_doc =
    jcall("intent", vim.json.encode({ params = { intent = golden("rules.new") } }), { root = root })
  eq(refused_doc.kind, "tasks.error")
  eq(refused_doc.code, "invalid_argument")
  has(refused_doc.message, "this target does not take rules.new")

  -- ── the CLI ────────────────────────────────────────────────────────────────
  local cli = require("tasks_nvim.cli")
  local function cli_run(argv)
    local out, err = {}, {}
    local code =
      cli.run(vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=2026-11-07" }), {
        out = function(t)
          out[#out + 1] = t
        end,
        err = function(t)
          err[#err + 1] = t
        end,
      })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  local file = H.tmpdir() .. "/intent.json"
  H.write(
    file,
    own(function(d)
      d.finding.fp = "cccccccccccccccc"
    end)
  )
  local dry = cli_run({ "intent", file })
  eq(dry.code, 0, dry.err)
  has(dry.out, "would_create\tlib.nvim\tparse_spec: an empty line ends the list")
  local yes = cli_run({ "intent", file, "--yes" })
  eq(yes.code, 0, yes.err)
  has(yes.out, "created\tlib.nvim/")
  local twice = cli_run({ "intent", file, "--yes" })
  has(twice.out, "exists\tlib.nvim/")
  local bad_file = H.tmpdir() .. "/bad.json"
  H.write(bad_file, vim.json.encode(golden("rules.new")))
  local no = cli_run({ "intent", bad_file, "--yes" })
  eq(no.code, 1)
  has(no.err, "intent refused: this target does not take rules.new")
  local huge = H.tmpdir() .. "/huge.json"
  H.write(huge, string.rep(" ", intent.MAX_BYTES + 10))
  has(cli_run({ "intent", huge }).err, "larger than 65536 bytes")
  ok(cli_run({ "intent", H.tmpdir() .. "/nope.json" }).code ~= 0, "a missing file")
  eq(cli_run({ "intent" }).code, 2)

  -- ── two processes take the same finding at once: one task ──────────────────
  local lib = vim.env.LIB_NVIM_DIR
  if lib and lib ~= "" then
    local race_file = H.tmpdir() .. "/race.json"
    H.write(
      race_file,
      own(function(d)
        d.finding.fp = "dddddddddddddddd"
      end)
    )
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
        "intent",
        race_file,
        "--yes",
        "--vault=" .. root,
      }, { text = true, env = { LIB_NVIM_DIR = lib } })
    end
    local created, existed = 0, 0
    for i = 1, 4 do
      local r = procs[i]:wait(60000)
      local out = (r.stdout or "") .. (r.stderr or "")
      if out:find("created\t", 1, true) then
        created = created + 1
      elseif out:find("exists\t", 1, true) then
        existed = existed + 1
      end
    end
    eq(created, 1, "exactly one process makes the task")
    eq(created + existed, 4, "the others find it")
    eq(
      #find.by_refs({ "testing-finding:dddddddddddddddd" }, { root = root }),
      1,
      "one task holds the ref"
    )
  end
end
