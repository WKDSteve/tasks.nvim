---@module 'tasks_nvim.agent_brief'
---@brief The "tasks family" brief for AI agents: how to read, claim, change, create and finish tasks with this CLI.
---
--- An agent (ai-desktop, ai.nvim) gets this text as a tool description or system block when a job comes from the tasks
--- family. It is generated, never written by hand twice: the command reference is the CLI's own `--help` text, and every
--- allowed value comes from `tasks_nvim.model` -- the same sources `--help`, `new`, `set` and `check` use, so the brief
--- cannot promise a value the engine refuses. The brief names the contract version (`contract.SCHEMA`) and the engine
--- version; an agent that holds an older brief compares `brief_version` and `contract_schema` with
--- `tasks agent-brief --format=json` (or `call hello`) and asks for a new one.

local claims = require("tasks_nvim.claims")
local contract = require("tasks_nvim.contract")
local json = require("lib.nvim.json.canonical")
local model = require("tasks_nvim.model")

local M = {}

---The version of this brief's layout. Raise it when a section changes meaning (not for new commands: those come with
---the usage text). 2: the staging rule in the workflow, the section "Checking" and `checks` of `--repo=<dir>`.
M.BRIEF_VERSION = 2

---The JSON schema name of `--format=json`.
M.SCHEMA_NAME = "tasks-agent-brief/1"

---The claim name an agent of ai-desktop uses unless the caller names one: `ai-desktop:<job>`, so tasks-desktop can show
---"agent works on it" and link the job.
M.DEFAULT_BY = "ai-desktop:<job>"

---@param list (string|integer)[]
---@return string
local function words(list)
  local out = {}
  for i, v in ipairs(list) do
    out[i] = "`" .. tostring(v) .. "`"
  end
  return table.concat(out, ", ")
end

---The name `--by` fills into the examples. It must be a name `claim` takes (`claims.valid_name`): an agent copies the
---examples into a shell, so a name the engine refuses would fail there, and a name with `$(...)` or a backtick would
---run as a command. Only the default placeholder `ai-desktop:<job>` is not such a name (the caller puts the job id in).
---@param by string|nil
---@return string|nil by, string|nil err
function M.check_by(by)
  if by == nil then
    return M.DEFAULT_BY
  end
  if not claims.valid_name(by) then
    return nil, "--by must be a claim name: 1-64 characters of letters, digits and . _ : @ -"
  end
  return by
end

-- ── checks of the target repository (`--repo=<dir>`) ───────────────────────

---How many VM instructions loading a `.testing.lua` may take before it counts as unreadable (a table literal takes a
---few thousand).
M.LOAD_BUDGET = 1000000

---A larger `.testing.lua` or `CLAUDE.md` is not read: no project's file comes near it.
local MAX_FILE_BYTES = 1024 * 1024

---@param path string
---@return string|nil
local function read_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > MAX_FILE_BYTES then
    return nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param t table
---@return table
local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

---Run a `.testing.lua` in an empty environment: only pure library functions, no `vim`, `os`, `io`, `require` or
---`load`, and a budget of instructions, so building a brief never starts a program or writes a file. The file has the
---same trust as the specs it configures (testing.nvim runs it with everything); the sandbox only keeps the brief free
---of side effects. A file that needs more (`vim.uv.cwd()`) does not load here: `nil`, and the caller reads its text.
---@param text string
---@return table|nil
local function load_sandboxed(text)
  if text:byte(1) == 27 then
    return nil -- bytecode
  end
  local chunk = loadstring(text, "=.testing.lua")
  if not chunk then
    return nil
  end
  local str = copy(string)
  str.rep, str.dump = nil, nil
  setfenv(chunk, {
    string = str,
    table = copy(table),
    math = copy(math),
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    select = select,
    unpack = unpack,
    error = error,
    assert = assert,
  })
  local hook, mask, count = debug.gethook()
  -- The hook may fire on any instruction until it is taken away again, also right after the chunk returned: it
  -- raises only while the chunk runs, and the flag is cleared inside the protected call, so nothing escapes it.
  local running = false
  debug.sethook(function()
    if running then
      error("instruction budget exceeded")
    end
  end, "", M.LOAD_BUDGET)
  local ok, value = pcall(function()
    running = true
    local result = chunk()
    running = false
    return result
  end)
  running = false
  debug.sethook(hook, mask, count)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

---`ci.workflow.land = true` read from the text of a `.testing.lua` that would not load in the sandbox: a line of code
---(comments cut off) with the key `land = true` (a whole word: `island = true` is another key).
---@param text string
---@return boolean
local function land_in_text(text)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local code = line:gsub("%-%-.*$", "")
    if code:match("%f[%w_]land%s*=%s*true%f[^%w_]") then
      return true
    end
  end
  return false
end

---The headings of the section in a `CLAUDE.md` that lists the checks before a commit (lower case).
M.CLAUDE_MD_HEADINGS = { "vor jedem commit", "before every commit", "before each commit" }

---The commands in the fenced blocks of the section "Vor jedem Commit" of a `CLAUDE.md`: one per line, a trailing
---`# comment` cut off, comment lines left out.
---@param text string
---@return string[]
function M.claude_md_commands(text)
  local commands = {}
  local level ---@type integer|nil the heading level of the section while inside it
  local fenced = false
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    local hashes, title = line:match("^(#+)%s+(.-)%s*$")
    if hashes and not fenced then
      if level and #hashes <= level then
        break
      end
      local lower = title:lower()
      for _, heading in ipairs(M.CLAUDE_MD_HEADINGS) do
        if not level and lower:find(heading, 1, true) == 1 then
          level = #hashes
        end
      end
    elseif line:match("^%s*```") then
      -- fences count everywhere: a `#` line inside a code block is a comment, never a heading
      fenced = not fenced
    elseif level and fenced then
      local cmd = vim.trim((line:gsub("%s+#.*$", "")))
      if cmd ~= "" and cmd:sub(1, 1) ~= "#" then
        commands[#commands + 1] = cmd
      end
    end
  end
  return commands
end

---@class tasks.AgentBriefChecks
---@field source "testing"|"claude-md"|"none" where the checks come from
---@field land boolean `ci.workflow.land = true`: `ci land` replaces the final run and the push
---@field per_commit string|nil after every commit (`<sha>` to fill in); `.testing.lua` only
---@field before_push string|nil once before the push, for everything that goes out; `.testing.lua` without land only
---@field commands string[]|nil the commands of the `CLAUDE.md` section (source `claude-md`)
---@field sync string|nil `git pull --rebase` before the final run (not with land: `ci land` rebases itself)
---@field review string what goes out: only own commits
---@field push string the push (or `ci land`)

---The checks of a repository, for an agent working in it. `opts.windows` (default: this machine) adds `--wsl` to the
---final run, as CI-02 asks on Windows.
---@param dir string
---@param opts? { windows?: boolean }
---@return tasks.AgentBriefChecks|nil checks, string|nil err
function M.checks(dir, opts)
  local stat = type(dir) == "string" and dir ~= "" and vim.uv.fs_stat(dir) or nil
  if not stat or stat.type ~= "directory" then
    return nil, "--repo must be a directory"
  end
  local windows = (opts or {}).windows
  if windows == nil then
    windows = jit.os == "Windows"
  end
  local review = "git log origin/main..HEAD"
  local sync = "git pull --rebase origin main"
  local push = "git push origin HEAD:main"
  local testing = read_file(dir .. "/.testing.lua")
  if testing then
    local cfg = load_sandboxed(testing)
    local land
    if cfg then
      local ci = type(cfg.ci) == "table" and cfg.ci or {}
      local workflow = type(ci.workflow) == "table" and ci.workflow or {}
      land = workflow.land == true
    else
      land = land_in_text(testing)
    end
    local stat_script = vim.uv.fs_stat(dir .. "/scripts/test.sh")
    local runner = (stat_script and stat_script.type == "file") and "scripts/test.sh" or "testing"
    return {
      source = "testing",
      land = land,
      per_commit = runner .. " ci commit <sha> --quick -- --cached",
      before_push = not land
          and (runner .. " ci commit HEAD --base=origin/main" .. (windows and " --wsl" or "") .. " -- --cached")
        or nil,
      sync = not land and sync or nil,
      review = review,
      push = land and (runner .. " ci land") or push,
    }
  end
  local claude = read_file(dir .. "/CLAUDE.md")
  local commands = claude and M.claude_md_commands(claude) or {}
  return {
    source = #commands > 0 and "claude-md" or "none",
    land = false,
    commands = #commands > 0 and commands or nil,
    sync = sync,
    review = review,
    push = push,
  }
end

---The section "Checking" of a brief for `checks`.
---@param c tasks.AgentBriefChecks
---@return string[]
local function checking_lines(c)
  local lines = { "## Checking (before commit and push)", "" }
  local function add(...)
    for _, l in ipairs({ ... }) do
      lines[#lines + 1] = l
    end
  end
  if c.source == "testing" then
    add(
      "The checks of this repository come from its `.testing.lua` (testing.nvim). Run them in this order:",
      "",
      ("1. After every commit: `%s` (fill in the commit's sha). It checks lint and the specs"):format(
        c.per_commit
      ),
      "   the commit reaches, in a worktree of its own, against its parent. The first line is the verdict: `CLEAN`,",
      "   `KNOWN-RED`, `FLAKY` = nothing new broke, go on; `REGRESSION` = fix it now, before the next step;",
      "   `UNCLASSIFIED` = read it and decide; `DOCS-ONLY` = nothing to run. A quick verdict never allows a push."
    )
    if c.land then
      add(
        ("2. Before landing: `%s` lists what goes out; only your own commits may be in it."):format(
          c.review
        ),
        ("3. Land instead of `git push`: `%s`. It pushes HEAD to a check branch, the hosted CI checks it"):format(
          c.push
        ),
        "   on every system and main moves only when that is green (no local full run needed). Exit 0 = landed;",
        "   1 = red: read the red system, fix it and land again. Never `git push` to main by hand in this repository."
      )
    else
      add(
        ("2. Before the push, once for everything that goes out: `%s`, then `%s`"):format(
          c.sync,
          c.review
        ),
        "   (only your own commits may be in it), then the full run of that state:",
        ("   `%s`. Push only on `CLEAN`, `KNOWN-RED` or `FLAKY`; a `REGRESSION` is fixed first."):format(
          c.before_push
        ),
        ("3. Push: `%s`."):format(c.push)
      )
    end
  elseif c.source == "claude-md" then
    add(
      "This repository has no `.testing.lua`. Its `CLAUDE.md` names these checks before every commit; all must pass:",
      ""
    )
    for _, cmd in ipairs(c.commands) do
      add("- `" .. cmd .. "`")
    end
    add(
      "",
      ("Before the push: `%s`, then `%s` (only your own commits may be in it), then `%s`."):format(
        c.sync,
        c.review,
        c.push
      )
    )
  else
    add(
      'This repository names no checks (no `.testing.lua`, no section "Vor jedem Commit" in its `CLAUDE.md`).',
      "",
      ("Before the push: `%s`, then `%s` (only your own commits may be in it), then `%s`."):format(
        c.sync,
        c.review,
        c.push
      )
    )
  end
  add("")
  return lines
end

---Build the brief as Markdown.
---@param opts { usage: string, by?: string, checks?: tasks.AgentBriefChecks }
---@return string
function M.markdown(opts)
  local by = opts.by or M.DEFAULT_BY
  local hours = math.floor(claims.DEFAULT_SECONDS / 3600)
  local max_hours = math.floor(claims.MAX_SECONDS / 3600)
  local lines = {
    "# Tasks family: working on a task vault",
    "",
    ("brief_version: %d · contract_schema: %d · engine: %s %s"):format(
      M.BRIEF_VERSION,
      contract.SCHEMA,
      contract.PLUGIN,
      contract.ENGINE_VERSION
    ),
    "",
    "You work on tasks of a task vault: one Markdown file per task in `<area>/ROADMAP/tasks/<slug>.md`, a task id is",
    "`<area>/<slug>`. Change the vault ONLY through the `tasks` command (below); it validates every value, regenerates",
    "the index `<area>/ROADMAP/TASKS.md` and moves finished tasks to `<area>/Backlog/`.",
    "",
    "## Workflow",
    "",
    ("1. Claim the task before you work on it: `tasks claim <id> --by=%s` (sets `status: doing`, reserves it for %dh,"):format(
      by,
      hours
    ),
    ("   `--for=2h` up to %dh, `--renew` extends). A claim of somebody else is refused with the owner's name: stop and"):format(
      max_hours
    ),
    "   report it, never pass it with `--force`.",
    "2. Read it: `tasks show <id>` (frontmatter, body, claim). Its `## Akzeptanz`/`## Acceptance` checklist is what",
    "   must be true at the end.",
    ("3. Work. Change fields with `tasks set <id> key=value ... --by=%s`; tick steps and add notes in the file body."):format(
      by
    ),
    ("4. New work you find: `tasks new <area> <title> --kind=... --prio=... --effort=... --value=... --by=%s`, never"):format(
      by
    ),
    "   a hand-written file.",
    ('5. Finish, after the push: `tasks done <id> --commits=repo@sha,... --ci=pending --done-in="<what was done>" --by=%s`.'):format(
      by
    ),
    "   `--ci=pending`: the hosted CI of the commits has no verdict yet (`--ci=green` only when it has passed on every",
    "   system, as after a landing); the verdict is written later with `tasks set <id> ci=green|red`, on the finished",
    ("   task too. It frees the claim. Giving it back unfinished: `tasks unclaim <id> --by=%s`."):format(
      by
    ),
    "",
    "Never write `status: done` by hand, never edit `ROADMAP/TASKS.md` or `Backlog/README.md`, never delete a task",
    "file. Commit the task file together with its area's `ROADMAP/TASKS.md`.",
    "",
    "Staging: other sessions work in the same checkouts and leave uncommitted changes. Stage only your own files, by",
    "path (`git add <path>`), never `git add -A`, `git add .` or `git commit -a`; look at `git diff --cached --stat`",
    "before every commit. Never commit, reset, stash or format a change that is not yours.",
    "",
    "## Fields and allowed values",
    "",
    "- `status`: " .. words(model.STATUSES) .. " (`done` only through `tasks done`)",
    "- `kind`: " .. words(model.KINDS),
    "- `prio`: " .. words(model.PRIOS) .. " (1 is the most urgent)",
    "- `effort`: " .. words(model.EFFORTS) .. " or days like `0.5d`",
    "- `value`: " .. words(model.VALUES) .. " (expected benefit)",
    "- `actor`: " .. words(model.ACTORS) .. " (who can do it; `me` = only the user)",
    "- `severity`: " .. words(model.SEVERITIES) .. " (bugs and security tasks)",
    "- `category`: " .. words(model.CATEGORIES),
    "- `scope`: " .. words(model.SCOPES),
    "- `plan`, `phase`, `after`, `blocked_by`, `refs`, `tags`, `due`, `start`: see `tasks set` and `tasks new` below",
    "",
  }
  if opts.checks then
    vim.list_extend(lines, checking_lines(opts.checks))
  end
  vim.list_extend(lines, {
    "## Exit codes and errors",
    "",
    "- 0: done; 1: refused or failed, the reason is on stderr as `error: <message>`; 2: wrong usage.",
    "- `<id> is claimed by <name> since ... until ...`: somebody else works on it. Stop and report.",
    "- `--format=json` (where offered) prints contract documents with `schema`; an error is a document too.",
    "",
    "## Command reference (`tasks --help`)",
    "",
    "Run every command as `tasks <command> ...` (or, without `bin/` on the PATH,",
    "`nvim -n -i NONE --headless -u NONE -l <checkout>/scripts/tasks.lua <command> ...` of a tasks.nvim checkout).",
    "`--vault=<dir>` or `$TASKS_VAULT` names the vault. A command to copy has no prompt (`>`, `$`) in front.",
    "",
    "```text",
    (opts.usage:gsub("\n+$", "")),
    "```",
    "",
  })
  return table.concat(lines, "\n")
end

---Build the brief as a JSON document (`tasks-agent-brief/1`). With `checks` (`--repo=<dir>`) it carries them as
---`checks` too, the exact commands a caller allows its agent to run.
---@param opts { usage: string, by?: string, checks?: tasks.AgentBriefChecks }
---@return string
function M.json(opts)
  return json.encode({
    schema = M.SCHEMA_NAME,
    brief_version = M.BRIEF_VERSION,
    contract_schema = contract.SCHEMA,
    plugin = contract.PLUGIN,
    engine_version = contract.ENGINE_VERSION,
    by = opts.by or M.DEFAULT_BY,
    checks = opts.checks,
    markdown = M.markdown(opts),
  }) .. "\n"
end

return M
