---@module 'tasks_nvim.mcp'
---@brief The read methods of `tasks-export/1` as MCP tools, served by `lib.nvim.mcp.server` (`scripts/mcp.lua`).
---@description
--- Each tool is one method of `tasks_nvim.api` (`lib.nvim.mcp.server.contract_tools`): the arguments are the method's
--- `params`, the answer is the document's canonical JSON, an error document (`tasks.error`) is an `isError` result.
---
--- Only reads. The write door `ops` (`tasks-ops/1`), `intent` (it saves with `yes`), `agent_answer` (it files an
--- answer) and `done_preview` (it mints the token a `done` needs) are left out on purpose: an agent that can finish or
--- rewrite tasks through a side door skips the claim, the review and the person who closes a task with `tasks done`.
--- A write tool would need its own policy (who may, with which confirmation); until that exists there is none. The
--- operations of the learning paths (`path_new`, `node_set`, `promote`, ...) are such writes and stay out as well.

local M = {}

---The tools, by method of `tasks_nvim.api`, with what the model reads about them.
---@type table<string, string>
M.TOOLS = {
  hello = "What this task engine is: its version, the contract schema and its capabilities.",
  list = "A page of open tasks in plan order (id, title, status, prio, effort, readiness). "
    .. "Filter by `area` and `status` (list), page with `limit` (1..100) and `offset`.",
  task = "One task by id (`<area>/<slug>`): frontmatter, body, plan steps, readiness. "
    .. "`finished = true` looks in the area's Backlog instead.",
  next = "What to start next: the best `n` (0..10) ready tasks, optionally for one `actor` or `area`.",
  areas = "The areas of the vault with their counts.",
  check = "The rule check of the vault (`tasks check`) as findings; `area` narrows it, "
    .. '`stale = "refs"` adds the tasks whose referenced files changed since. Slow on a large vault.',
  find = "The open tasks that name one of the files in `refs` (vault-relative paths).",
  waits = "What open tasks wait for (`waits_for`), grouped; optionally of one `area`.",
  finished = "Finished tasks from the Backlogs (newest first), with filters and paging.",
  paths = "The open learning paths (`<area>/ROADMAP/paths/`) with their progress "
    .. "(learned, seen, dropped, open, blocked); optionally of one `area`.",
  path = "One learning path by id: its body and its tree of learning points as a flat list "
    .. "(state, derived state, progress per point, key, reason, the task a point was promoted to).",
  milestones = "The milestones (`<area>/ROADMAP/milestones/`): due date, reached date, status and the "
    .. "progress over their members (tasks, plans, projects, paths, meetings); optionally of one `area`.",
  milestone = "One milestone by id: its members with kind, state and what each counts, its history "
    .. "(reached, opened again) and its body.",
}

---The server over the vault `opts.root` (nil: `$TASKS_VAULT`, as the command line).
---@param opts? { root?: string }
---@return Lib.Mcp.Server
function M.server(opts)
  opts = opts or {}
  local mcp_server = require("lib.nvim.mcp.server")
  local contract = require("tasks_nvim.contract")
  local tools = mcp_server.contract_tools(require("tasks_nvim.api"), {
    prefix = "tasks_",
    methods = M.TOOLS,
    opts = function()
      return { root = opts.root }
    end,
  })
  return mcp_server.new({
    name = "tasks.nvim",
    version = contract.ENGINE_VERSION,
    instructions = "Read-only tools over a tasks vault (tasks-export/1): list, show, next, check. "
      .. "Ids are `<area>/<slug>`. Nothing here changes a task; finishing one is `tasks done` by a person.",
    tools = tools,
  })
end

return M
