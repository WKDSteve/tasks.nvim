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
---the usage text).
M.BRIEF_VERSION = 1

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

---Build the brief as Markdown.
---@param opts { usage: string, by?: string }
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
    ('5. Finish: `tasks done <id> --commits=repo@sha,... --done-in="<what was done>" --by=%s`. It frees the claim.'):format(
      by
    ),
    ("   Giving it back unfinished: `tasks unclaim <id> --by=%s`."):format(by),
    "",
    "Never write `status: done` by hand, never edit `ROADMAP/TASKS.md` or `Backlog/README.md`, never delete a task",
    "file. Commit the task file together with its area's `ROADMAP/TASKS.md`.",
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
    "## Exit codes and errors",
    "",
    "- 0: done; 1: refused or failed, the reason is on stderr as `error: <message>`; 2: wrong usage.",
    "- `<id> is claimed by <name> since ... until ...`: somebody else works on it. Stop and report.",
    "- `--format=json` (where offered) prints contract documents with `schema`; an error is a document too.",
    "",
    "## Command reference (`tasks --help`)",
    "",
    "Run every command as `tasks <command> ...` (or `nvim --headless -u NONE -l scripts/tasks.lua <command> ...` of a",
    "tasks.nvim checkout). `--vault=<dir>` or `$TASKS_VAULT` names the vault.",
    "",
    "```text",
    (opts.usage:gsub("\n+$", "")),
    "```",
    "",
  }
  return table.concat(lines, "\n")
end

---Build the brief as a JSON document (`tasks-agent-brief/1`).
---@param opts { usage: string, by?: string }
---@return string
function M.json(opts)
  return json.encode({
    schema = M.SCHEMA_NAME,
    brief_version = M.BRIEF_VERSION,
    contract_schema = contract.SCHEMA,
    plugin = contract.PLUGIN,
    engine_version = contract.ENGINE_VERSION,
    by = opts.by or M.DEFAULT_BY,
    markdown = M.markdown(opts),
  }) .. "\n"
end

return M
