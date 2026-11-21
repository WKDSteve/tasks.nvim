-- TESTS/tasks_agent_brief_spec.lua -- `agent-brief`: the tasks-family brief for AI agents (tasks_nvim.agent_brief).

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local cli = require("tasks_nvim.cli")
  local brief = require("tasks_nvim.agent_brief")
  local contract = require("tasks_nvim.contract")
  local model = require("tasks_nvim.model")

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end

  -- ── Markdown: no vault needed, versions on top ─────────────────────────
  local r = run({ "agent-brief" })
  eq(r.code, 0, "agent-brief runs without a vault: " .. r.err)
  has(r.out, "# Tasks family: working on a task vault")
  has(r.out, ("brief_version: %d"):format(brief.BRIEF_VERSION))
  has(r.out, ("contract_schema: %d"):format(contract.SCHEMA), "names the contract version")
  has(r.out, contract.ENGINE_VERSION, "names the engine version")

  -- the workflow uses the default claim name of ai-desktop in every example
  has(r.out, "tasks claim <id> --by=ai-desktop:<job>")
  has(r.out, "tasks done <id> --commits=repo@sha,...")
  has(r.out, "--by=ai-desktop:<job>`.\n   It frees the claim.")
  has(r.out, "tasks unclaim <id> --by=ai-desktop:<job>")
  has(r.out, "never pass it with `--force`", "a foreign claim is a stop, not a force")

  -- every allowed value comes from the model, so the brief and the engine never disagree
  for _, list in ipairs({
    model.KINDS,
    model.STATUSES,
    model.EFFORTS,
    model.ACTORS,
    model.CATEGORIES,
    model.SCOPES,
  }) do
    for _, word in ipairs(list) do
      has(r.out, "`" .. word .. "`", "allowed value " .. word)
    end
  end

  -- the command reference is the CLI's own usage text, in one fenced block
  local help = run({ "--help" })
  eq(help.code, 0)
  has(r.out, "```text\n" .. help.out:gsub("\n+$", "") .. "\n```", "the usage text verbatim")
  has(help.out, "agent-brief [--format=md|json]", "--help lists the command")
  local _, fences = r.out:gsub("```", "")
  eq(fences, 2, "exactly one fenced block (the usage has no fence of its own)")

  -- ── --by: the claim name of the examples ───────────────────────────────
  r = run({ "agent-brief", "--by=ai-desktop:job-42" })
  eq(r.code, 0)
  has(r.out, "tasks claim <id> --by=ai-desktop:job-42")
  lacks(r.out, "--by=ai-desktop:<job>", "the default is replaced in every example")

  -- only a name `claim` takes: an agent copies the examples into a shell, so `$(...)` or a backtick must never get in
  for _, bad in ipairs({
    "--by=",
    "--by=two words",
    "--by=a\tb",
    "--by=$(whoami)",
    "--by=a`id`",
    "--by=a;b",
    "--by=a/b",
    "--by=" .. string.rep("x", 65),
  }) do
    r = run({ "agent-brief", bad })
    eq(r.code, 2, "refused: " .. bad)
    has(r.err, "--by must be a claim name")
    eq(r.out, "", "nothing printed for a refused name")
  end
  ok(brief.check_by(string.rep("x", 64)), "64 characters are fine")
  ok(brief.check_by("cdx:ab12cd34"), "the editor's own claim name is fine")
  ok(brief.check_by("me@host.local"), "user@host is fine")

  -- ── usage errors ───────────────────────────────────────────────────────
  r = run({ "agent-brief", "--format=yaml" })
  eq(r.code, 2)
  has(r.err, "--format must be md or json")
  r = run({ "agent-brief", "extra" })
  eq(r.code, 2)
  has(r.err, "takes no positional argument")

  -- ── JSON: versions for the caller to compare, the Markdown inside ──────
  r = run({ "agent-brief", "--format=json" })
  eq(r.code, 0)
  local doc = vim.json.decode(r.out)
  eq(doc.schema, "tasks-agent-brief/1")
  eq(doc.brief_version, brief.BRIEF_VERSION)
  eq(doc.contract_schema, contract.SCHEMA)
  eq(doc.engine_version, contract.ENGINE_VERSION)
  eq(doc.plugin, contract.PLUGIN)
  eq(doc.by, "ai-desktop:<job>")
  eq(doc.markdown, run({ "agent-brief" }).out, "the same Markdown as --format=md")
  eq(run({ "agent-brief", "--format=json" }).out, r.out, "byte for byte the same on a second run")
  has(r.out, '{"brief_version":', "canonical key order (sorted)")
  eq(doc.checks, nil, "no checks without --repo")
  eq(brief.BRIEF_VERSION, 2, "the layout with the staging rule and the section Checking")

  -- ── staging (GIT-05): always in the workflow ──────────────────────────
  local md = run({ "agent-brief" }).out
  has(md, "Stage only your own files, by")
  has(md, "never `git add -A`, `git add .` or `git commit -a`")
  has(md, "`git diff --cached --stat`")
  lacks(md, "## Checking", "no section Checking without --repo")
  has(md, "5. Finish, after the push: `tasks done <id>")

  -- ── --repo: the checks of the target repository ───────────────────────
  local root = H.tmpdir()
  ---@param name string
  ---@param files table<string, string>
  ---@return string
  local function repo(name, files)
    local dir = root .. "/" .. name
    vim.fn.mkdir(dir, "p")
    for path, content in pairs(files) do
      H.write(dir .. "/" .. path, content)
    end
    return dir
  end
  local SCRIPT = "#!/usr/bin/env bash\n"

  -- a repository of testing.nvim, pushed to main: quick per commit, the final run before the push
  local plain = repo("plain", {
    [".testing.lua"] = 'return { plugin = "x", ci = { workflow = { name = "x" } } }\n',
    ["scripts/test.sh"] = SCRIPT,
  })
  eq(brief.checks(plain, { windows = true }), {
    source = "testing",
    land = false,
    per_commit = "scripts/test.sh ci commit <sha> --quick -- --cached",
    before_push = "scripts/test.sh ci commit HEAD --base=origin/main --wsl -- --cached",
    sync = "git pull --rebase origin main",
    review = "git log origin/main..HEAD",
    push = "git push origin HEAD:main",
  }, "the checks of a repository pushed to main")
  eq(
    brief.checks(plain, { windows = false }).before_push,
    "scripts/test.sh ci commit HEAD --base=origin/main -- --cached",
    "--wsl only on Windows"
  )

  r = run({ "agent-brief", "--repo=" .. plain })
  eq(r.code, 0, r.err)
  has(r.out, "## Checking (before commit and push)")
  has(r.out, "1. After every commit: `scripts/test.sh ci commit <sha> --quick -- --cached`")
  has(r.out, "`git pull --rebase origin main`, then `git log origin/main..HEAD`")
  has(
    r.out,
    "`" .. brief.checks(plain).before_push .. "`. Push only on `CLEAN`, `KNOWN-RED` or `FLAKY`"
  )
  has(r.out, "3. Push: `git push origin HEAD:main`.")
  lacks(r.out, "ci land")
  lacks(r.out, plain, "the brief never names the path of this machine")
  ok(
    r.out:find("## Checking", 1, true) < r.out:find("## Exit codes", 1, true),
    "Checking before the reference"
  )

  r = run({ "agent-brief", "--repo=" .. plain, "--format=json" })
  eq(r.code, 0, r.err)
  doc = vim.json.decode(r.out)
  eq(doc.checks, brief.checks(plain), "JSON carries the checks the caller allows")
  eq(doc.markdown, run({ "agent-brief", "--repo=" .. plain }).out, "and the same Markdown")
  lacks(r.out, plain, "no path of this machine in the document")

  -- ci.workflow.land = true: `ci land` replaces the final run and the push (CI-05)
  local land = repo("land", {
    [".testing.lua"] = "return {\n  ci = {\n    workflow = {\n      land = true,\n    },\n  },\n}\n",
    ["scripts/test.sh"] = SCRIPT,
  })
  eq(brief.checks(land, { windows = true }), {
    source = "testing",
    land = true,
    per_commit = "scripts/test.sh ci commit <sha> --quick -- --cached",
    review = "git log origin/main..HEAD",
    push = "scripts/test.sh ci land",
  }, "land: no local final run, no git pull, the push is `ci land`")
  r = run({ "agent-brief", "--repo=" .. land })
  eq(r.code, 0, r.err)
  has(r.out, "3. Land instead of `git push`: `scripts/test.sh ci land`.")
  lacks(r.out, "git push origin HEAD:main", "never a plain push where the repository lands")
  lacks(r.out, "--base=origin/main")

  -- no scripts/test.sh: the `testing` command itself
  local bare =
    repo("bare", { [".testing.lua"] = "return { ci = { workflow = { land = true } } }\n" })
  eq(brief.checks(bare).per_commit, "testing ci commit <sha> --quick -- --cached")
  eq(brief.checks(bare).push, "testing ci land")

  -- a .testing.lua that needs the editor (vim.uv.cwd()) does not load in the sandbox: its text decides about land
  local needs_vim = repo("needs-vim", {
    [".testing.lua"] = "return {\n  setup = { root = vim.uv.cwd() },\n  ci = { workflow = {\n    land = true, -- hosted\n  } },\n}\n",
  })
  eq(brief.checks(needs_vim).land, true, "land read from the text")
  local commented = repo("commented", {
    [".testing.lua"] = "return {\n  setup = { root = vim.uv.cwd() },\n  -- land = true,\n  island = true,\n}\n",
  })
  eq(
    brief.checks(commented).land,
    false,
    "a commented-out land and another key ending in land do not count"
  )
  local one_line = repo("one-line", {
    [".testing.lua"] = "return { root = vim.uv.cwd(), ci = { workflow = { land = true } } }\n",
  })
  eq(brief.checks(one_line).land, true, "land inside a line of code")

  -- the loaded table decides when the file loads: a land the text shows but the table does not have is no land
  local loaded = repo("loaded", {
    [".testing.lua"] = "local unused = { land = true }\nreturn { ci = { workflow = { land = false } } }\n",
  })
  eq(brief.checks(loaded).land, false, "the table, not the text")

  -- the sandbox: loading starts nothing, writes nothing and ends a loop that never ends
  local marker = root .. "/marker.txt"
  local evil = repo("evil", {
    [".testing.lua"] = ('io.open(%q, "w"):write("x")\nos.execute("exit 3")\nreturn { ci = { workflow = {} } }\n'):format(
      marker
    ),
  })
  eq(
    brief.checks(evil).source,
    "testing",
    "a file that reaches for io/os still names the testing.nvim checks"
  )
  eq(H.exists(marker), false, "nothing written while building the brief")
  local loop = repo("loop", { [".testing.lua"] = "while true do end\n" })
  eq(brief.checks(loop).land, false, "the instruction budget ends an endless loop")
  local loop_land =
    repo("loop-land", { [".testing.lua"] = "local c = { land = true }\nwhile true do end\n" })
  eq(brief.checks(loop_land).land, true, "a file that does not load falls back to its text")

  -- ── without .testing.lua: what CLAUDE.md names before every commit, nothing else ──
  local claude = repo("claude", {
    ["CLAUDE.md"] = table.concat({
      "# demo",
      "",
      "```",
      "outside --section",
      "```",
      "",
      "## Vor jedem Commit (alles muss grün sein)",
      "",
      "```bash",
      "cargo fmt --check",
      "# a comment line",
      "cargo clippy -- -D warnings    # zero warnings",
      "",
      "```",
      "",
      "### a sub-heading stays in the section",
      "",
      "```",
      "pnpm test",
      "```",
      "",
      "## Git",
      "",
      "```",
      "git push --force",
      "```",
    }, "\r\n"),
  })
  eq(brief.checks(claude), {
    source = "claude-md",
    land = false,
    commands = { "cargo fmt --check", "cargo clippy -- -D warnings", "pnpm test" },
    sync = "git pull --rebase origin main",
    review = "git log origin/main..HEAD",
    push = "git push origin HEAD:main",
  }, "the commands of the section, nothing before or after it")
  r = run({ "agent-brief", "--repo=" .. claude })
  eq(r.code, 0, r.err)
  has(r.out, "Its `CLAUDE.md` names these checks before every commit")
  has(r.out, "- `cargo clippy -- -D warnings`")
  lacks(r.out, "ci commit", "no testing.nvim commands without .testing.lua")
  lacks(r.out, "git push --force")
  eq(
    brief.claude_md_commands("## Before every commit\n\n```\nmake check\n```\n"),
    { "make check" },
    "English heading"
  )

  local none = repo("none", { ["CLAUDE.md"] = "# demo\n\n## Git\n\n```\ngit status\n```\n" })
  eq(brief.checks(none), {
    source = "none",
    land = false,
    sync = "git pull --rebase origin main",
    review = "git log origin/main..HEAD",
    push = "git push origin HEAD:main",
  }, "no checks named: none invented")
  r = run({ "agent-brief", "--repo=" .. none })
  has(r.out, "This repository names no checks")
  lacks(r.out, "ci commit")
  eq(brief.checks(repo("empty", {})).source, "none", "neither file")

  -- usage errors of --repo
  for _, bad in ipairs({
    "--repo=" .. root .. "/no-such-dir",
    "--repo=" .. claude .. "/CLAUDE.md",
    "--repo=",
  }) do
    r = run({ "agent-brief", bad })
    eq(r.code, 2, "refused: " .. bad)
    has(r.err, "--repo must be a directory")
    eq(r.out, "")
  end
end
