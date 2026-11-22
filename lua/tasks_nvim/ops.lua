---@module 'tasks_nvim.ops'
---@brief The write door of the machine contract, `tasks-ops/1`: a list of operations, answered with one `tasks.result`.
---@description
--- A front end that is not the editor (an app, an agent) changes the vault only through here. A request is
---
---   { "schema": 1, "client_op_id": "c-81f2", "dry_run": false, "ops": [ { "op": "set", ... }, ... ] }
---
--- and the answer is a `tasks.result` with one entry per operation: what happened (`changed`, `unchanged`, `created`,
--- `done`, or `failed` with an error that says why), the version of the file before and after (`etag_before`,
--- `etag_after`), and for an undo the `inverse` operation. Operations:
---
---  - `set` { id, patch, if_match?, expect? }: change frontmatter keys; `null` in the patch removes a key.
---    `if_match` (the task's `etag`) and `expect` ({ key, value }) are checked UNDER the file lock, so two writers
---    cannot both win; a change of the relations (`blocked_by`, `after`, `plan`, `phase`) is judged first
---    (`tasks_nvim.edges`)
---  - `new` { area, title, fields?, body? }: create a task; `body` (text, at most 20000 characters) replaces the template
---    sections of the file; `fields` are the keys (kind, prio, effort, tags, category, severity, value, actor, due, start, repeat, repeat_from, repeat_after, summary,
---    refs, links, status, slug, after, plan, phase); `after`, `plan` and `phase` are judged as `set` judges them
---    (`tasks_nvim.edges`: a target that exists nowhere, a plan that is no plan file, a phase not in its `phase_order`)
---  - `reorder` { id, after?, before?, group?, if_match? }: move a task inside its group (`batch.reorder`)
---  - `done` { id, confirm, done_in?, commits?, remind? }: finish a task (`commits`: `repo@sha` entries added to the task's own). `confirm` is the token of `done_preview` for the version of the
---    file that was shown; a task that changed since is a `conflict`
---  - `tick_step` { id, n, done?, if_match? }: tick (`done` true, the default) or untick step `n` of the `## Plan` section of an
---    open task; a dropped step is refused; the answer has an `inverse`
---  - `add_steps` { id, steps, if_match? }: append open steps (one line of text each, at most 100) to the `## Plan`
---    section of an open task, numbered on from its last step; a task without the section gets one before its notes.
---    Existing steps stay as they were; the answer has an `inverse` (a `set_body` with the old text)
---  - `append_note` { id, text, if_match? }: add one dated line to the notes of an open task (`## Notizen` / `## Notes`,
---    made when missing); no `inverse`
---  - `set_section` { id, heading, text, if_match? }: set the section `heading` (`## ...`) of the body of an open task, or
---    of a finished one in `Backlog/`, to `text` (replacing a section of that heading, else added at the end; at most
---    32768 characters, no '## ' heading inside); the answer has an `inverse` when a section was replaced
---  - `set_body` { id, body, if_match? }: replace the text below the frontmatter of an open task (at most 100000 characters, no
---    control character but the line break and the tab; an empty text is allowed and leaves one blank line); the answer has an
---    `inverse` (the old text) when the old text is within the same limit
---  - `reopen` { id, status?, if_match? }: bring a finished task back to `ROADMAP/tasks` (status `open`, or the one
---    given), take its row out of the Backlog README; an open task is `unchanged`; a folder task is refused; no `inverse`
---  - `move_area` { id, to_area, if_match? }: a dry run answers the report of `moves.preview` (new id, conflicts, what names
---    the old id); without it the open task moves to the other area under the same slug and every `blocked_by`, `after`,
---    `refs` and plan `target` that named the old id names the new one, all or nothing (`moves.move`); the answer has an
---    `inverse` (`move_area` back, with the version of the moved file)
---  - `plan_new` { area, title, areas?, target?, phases?, gate?, status?, summary?, slug?, project?, phase? }: make a plan file
---    (`project` and `phase` put it into a project and a stage of it); a dry run names the id it would get and whether the
---    slug had to be changed (`plans.new`)
---  - `project_new` { area, title, areas?, target?, phases?, gate?, status?, summary?, slug?, template? }: make a project
---    file under `ROADMAP/projects/` (the same as `plan_new`, without `project` and `phase`; `template: "learning"`
---    writes a curriculum of learning paths with the generated block of its paths)
---  - `plan_set` / `project_set` { id, patch, if_match? }: change the frontmatter of an open plan or project file (`title`,
---    `status`, `areas`, `target`, `phase_order`, `gate`; a plan also `project`, `phase`); `null` or an empty value removes a
---    key; the change is judged as the file would read afterwards, a fault it brings refuses it with `problems`; the answer
---    has an `inverse`. A plan is finished with `plan_close`, not by `status: done`
---  - `path_set` { id, patch, if_match? }: the same for a learning path (`title`, `status`, `areas`, `target`, `project`,
---    `links`, `icon`, `cover`, `tags`)
---  - `plan_close` / `project_close` { id }: finish a plan or project by hand: refused (`invalid_argument`, the holders are in
---    `details.holding`) while a task of the plan, or a task of its own or a plan or learning path other than a parked
---    one of the project, is open; `plan_close` goes on to the project when the plan was its last; no `inverse`
---
---  - `view_save` { id | area (slug?), view, if_match? }: make or replace a saved view of the tasks (`tasks_nvim.views`: a small
---    file at `<area>/ROADMAP/views/<slug>.md`). `view` is `{ title, display, group_by, group_by2?, collapsed?, select? }`; with
---    `area` alone a new view is made under a name taken from the title, with `id` (`<area>/<slug>`, or `area` and `slug`) the
---    view of that name is replaced, and only on the version the caller read (`if_match`: a view that exists and no tag is a
---    `conflict`; a name that is free is made); the answer has an `inverse`
---  - `view_delete` { id, if_match }: delete a saved view, on the version read (a view is shared by every machine of the
---    vault: a delete without it could take away a change made elsewhere); the answer has an `inverse` (the view made again)
---  - `attach` { id, from, name? }: the clipboard image (`from` `clipboard`) or the newest screenshot of the configured folders
---    (`latest`) becomes an asset of the task (a plain task becomes a folder task); the answer has `asset`, `link` and no
---    `inverse`. A request names no path of this machine; a dry run reads neither the clipboard nor a folder.
---    `from` `upload` takes the file `upload` (a plain name) from the folder the caller of the engine named with
---    `upload_dir`, and the asset is called `name` (a taken name gets a counter); with `exact` it is called `name` or
---    nothing is attached: a name the task has already is `exists`, in a dry run too (a file sent again after its
---    answer was lost arrives once)
---
---  - `milestone_new` { area, title, due?, includes?, close?, status?, summary?, slug? }: make a milestone under
---    `ROADMAP/milestones/` (`tasks_nvim.milestones`); `includes` must name tasks, plans, projects, paths or meetings of
---    this vault (`details.problems` names the others)
---  - `milestone_set` { id, patch, if_match? }: change `title`, `status`, `due`, `includes`, `close`, `summary`; `status`
---    `done` reaches it by hand (refused while a member is not done, `details.holding`); the answer has an `inverse`
---  - every operation that can finish or open a member of a milestone (`done`, `reopen`, `plan_close`, `project_close`,
---    `path_close`, `meeting_close`, `meeting_set`, `milestone_new`, `milestone_set`) brings the milestones in line
---    afterwards (`milestones.settle`): `milestones_reached` and `milestones_reopened` in its entry name what changed
---
---  - `meeting_new`, `meeting_set`, `meeting_close`, `meeting_capture`, `meeting_attend`, `meeting_followups`,
---    `board_save`: the meetings (`tasks_nvim.meeting_write`, docs/CONTRACT.md); `tick_step`, `add_steps`
---    (`section`), `append_note`, `set_section`, `set_body` and `attach` take a meeting id as well
---
--- Rules the door keeps:
---  - **the shape is checked first**, for the whole request: an unknown operation or field, a wrong type, too many
---    operations is `invalid_argument` and nothing runs. After that every operation runs on its own: one that fails
---    does not stop the others (this is NOT all-or-nothing, and the answer never says "ok" for a part);
---  - **`dry_run`** checks everything - the patch, the version, the relations, the slug - and writes nothing; the
---    tasks, plans and projects earlier operations of the request would create count as the real run has them;
---  - **limits are kept on writing** (title 300, summary 1000, lists of 100, 300 characters an entry), and a `refs`
---    entry that is new must be a plain relative path (no `..`, no drive or network prefix, no colon but a line
---    suffix); entries the task already has stay as they are;
---  - **no path of this machine in an error**, ids only;
---  - the index of an area is written once at the end, however many tasks of it changed.
---
--- Not its job: parsing the request line (`api`), the documents of the read side (`contract`).

local batch = require("tasks_nvim.batch")
local claims = require("tasks_nvim.claims")
local contract = require("tasks_nvim.contract")
local done_flow = require("tasks_nvim.done_flow")
local edges = require("tasks_nvim.edges")
local errors = require("lib.nvim.contract.errors")
local contract_ops = require("lib.nvim.contract.ops")
local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local gitbusy = require("tasks_nvim.gitbusy")
local history = require("tasks_nvim.history")
local index = require("tasks_nvim.index")
local json = require("lib.nvim.json.canonical")
local model = require("tasks_nvim.model")
local moves = require("tasks_nvim.moves")
local mutate = require("tasks_nvim.mutate")
local scan = require("tasks_nvim.scan")
local sections = require("tasks_nvim.sections")
local questions = require("tasks_nvim.questions")
local steps = require("tasks_nvim.steps")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---The write door (`lib.nvim.contract.ops`), made at the bottom of this file.
---The handlers are inputs of `contract_ops.make`, so they reach the door only through the two helpers below.
---@type Lib.Contract.Ops
local door

---The entry of an operation that failed: `door.failure` with the root of this request (hidden in the message).
---@param ctx Tasks.OpsCtx
---@param err any
---@param info? table
---@return table
local function fail(ctx, err, info)
  return door.failure(ctx.root, err, info)
end

---The entry of an operation refused with a code of its own (`door.refuse`).
---@param code string
---@param message string
---@param details? table
---@return table
local function refuse(code, message, details)
  return door.refuse(code, message, details)
end

---The operations, in the order the documentation names them.
M.OPS = {
  "set",
  "new",
  "reorder",
  "done",
  "move_area",
  "plan_new",
  "plan_set",
  "plan_close",
  "project_new",
  "project_set",
  "project_close",
  "tick_step",
  "add_steps",
  "answer",
  "append_note",
  "reopen",
  "set_body",
  "set_section",
  "view_save",
  "view_delete",
  "attach",
  "claim",
  "release",
  "history_record",
  "meeting_new",
  "meeting_set",
  "meeting_close",
  "meeting_capture",
  "meeting_attend",
  "meeting_followups",
  "board_save",
  "path_new",
  "path_set",
  "path_close",
  "node_set",
  "promote",
  "unpromote",
  "path_reward",
  "path_levels",
  "milestone_new",
  "milestone_set",
}

---The operations after which the milestones are brought in line (`milestones.settle`); `done` does it in its flow.
---@type table<string, boolean>
local SETTLES = {
  reopen = true,
  plan_close = true,
  project_close = true,
  path_close = true,
  meeting_close = true,
  meeting_set = true,
  milestone_new = true,
  milestone_set = true,
}

---Longest `client_op_id`.
M.MAX_CLIENT_OP_ID = 64

---Longest `body` of `new`, in characters.
M.MAX_BODY = 20000

---Longest `body` of `set_body`, in characters (the text a task file may grow to is not bounded by `new`).
M.MAX_SET_BODY = 100000
-- A section of `set_section` (a review, a proposal): at most this many characters, its heading at most 200.
M.MAX_SECTION = 32768

---Longest entry of a list value (a tag, a ref, an id).
M.MAX_ENTRY = 300

---Who acts and whether a claim of somebody else may be passed: carried by every operation that changes an open task
---(`tasks_nvim.claims`; the answer to a claimed task is `conflict` with the owner's name in the message).
local CLAIM_FIELDS = { by = "string", force = "boolean", note = "string" }

---What each operation may carry, and of what type. A field that is not listed is refused.
---@type table<string, table<string, string>>
local FIELDS = {
  set = { id = "string", patch = "object", if_match = "string", expect = "object" },
  new = { area = "string", title = "string", fields = "object", body = "string" },
  reorder = {
    id = "string",
    after = "string",
    before = "string",
    group = "string",
    if_match = "string",
  },
  done = {
    id = "string",
    confirm = "string",
    done_in = "strings",
    commits = "strings",
    remind = "string",
    outcome = "string",
    outcome_reason = "string",
    ci = "string",
    ack = "boolean",
  },
  move_area = { id = "string", to_area = "string", if_match = "string" },
  tick_step = {
    id = "string",
    n = "integer",
    done = "boolean",
    section = "string",
    if_match = "string",
  },
  add_steps = { id = "string", steps = "strings", section = "string", if_match = "string" },
  answer = {
    id = "string",
    question = "string",
    option = "integer",
    clear = "boolean",
    if_match = "string",
  },
  append_note = { id = "string", text = "string", if_match = "string" },
  reopen = { id = "string", status = "string", if_match = "string" },
  set_body = { id = "string", body = "string", if_match = "string" },
  set_section = { id = "string", heading = "string", text = "string", if_match = "string" },
  view_save = {
    id = "string",
    area = "string",
    slug = "string",
    view = "object",
    if_match = "string",
  },
  view_delete = { id = "string", if_match = "string" },
  attach = {
    id = "string",
    from = "string",
    name = "string",
    upload = "string",
    exact = "boolean",
    kind = "string",
  },
  claim = {
    id = "string",
    by = "string",
    ["for"] = "string",
    renew = "boolean",
    force = "boolean",
    note = "string",
  },
  release = { id = "string", by = "string", force = "boolean", note = "string", status = "string" },
  plan_new = {
    area = "string",
    title = "string",
    areas = "strings",
    target = "string",
    phases = "strings",
    gate = "string",
    status = "string",
    summary = "string",
    slug = "string",
    project = "string",
    phase = "string",
    links = "strings",
    icon = "string",
    cover = "string",
    template = "string",
  },
  project_new = {
    area = "string",
    title = "string",
    areas = "strings",
    target = "string",
    phases = "strings",
    gate = "string",
    status = "string",
    summary = "string",
    slug = "string",
    links = "strings",
    icon = "string",
    cover = "string",
    template = "string",
    requires = "strings",
    requires_gate = "string",
  },
  plan_set = { id = "string", patch = "object", if_match = "string" },
  project_set = { id = "string", patch = "object", if_match = "string" },
  plan_close = { id = "string" },
  project_close = { id = "string" },
  path_new = {
    area = "string",
    title = "string",
    areas = "strings",
    target = "string",
    status = "string",
    summary = "string",
    slug = "string",
    project = "string",
    links = "strings",
    icon = "string",
    cover = "string",
    template = "string",
    requires = "strings",
    requires_gate = "string",
  },
  path_set = { id = "string", patch = "object", if_match = "string" },
  path_close = { id = "string" },
  node_set = {
    id = "string",
    point = "string",
    state = "string",
    reason = "string",
    note = "string",
    xp = "integer",
    xp_clear = "boolean",
    ack = "boolean",
    if_match = "string",
  },
  path_reward = { id = "string", level = "string", given = "boolean", if_match = "string" },
  path_levels = { id = "string", levels = "object", if_match = "string" },
  milestone_new = {
    area = "string",
    title = "string",
    due = "string",
    includes = "strings",
    close = "string",
    status = "string",
    summary = "string",
    slug = "string",
  },
  milestone_set = { id = "string", patch = "object", if_match = "string" },
  promote = {
    container = "string",
    point = "string",
    area = "string",
    title = "string",
    actor = "string",
    if_match = "string",
  },
  -- `id` (the promoted task) is what the inverse of `promote` names for the reader; the point decides
  unpromote = { id = "string", container = "string", point = "string", if_match = "string" },
  history_record = {},
  meeting_new = {
    area = "string",
    title = "string",
    fields = "object",
    body = "string",
    slug = "string",
    lang = "string",
  },
  meeting_set = { id = "string", patch = "object", if_match = "string" },
  meeting_close = { id = "string", result = "string", if_match = "string" },
  meeting_capture = { id = "string", entry = "object", if_match = "string" },
  meeting_attend = {
    id = "string",
    n = "integer",
    name = "string",
    present = "boolean",
    if_match = "string",
  },
  meeting_followups = { id = "string", n = "integer", area = "string", fields = "object" },
  board_save = {
    id = "string",
    name = "string",
    format = "string",
    upload = "string",
    preview = "string",
    if_match = "string",
  },
}

for _, name in ipairs({
  "set",
  "reorder",
  "done",
  "move_area",
  "tick_step",
  "add_steps",
  "answer",
  "append_note",
  "reopen",
  "set_body",
  "set_section",
  "attach",
}) do
  FIELDS[name] = vim.tbl_extend("error", FIELDS[name], CLAIM_FIELDS)
end

---@param names table<string, any>
---@return string
local function sorted_names(names)
  local out = vim.tbl_keys(names)
  table.sort(out)
  return table.concat(out, ", ")
end

---The plain keys `new` takes in `fields`.
---@type table<string, boolean>
local NEW_FIELDS = {
  kind = true,
  prio = true,
  effort = true,
  tags = true,
  category = true,
  scope = true,
  severity = true,
  waits_for = true,
  value = true,
  xp = true,
  actor = true,
  summary = true,
  refs = true,
  links = true,
  icon = true,
  cover = true,
  status = true,
  slug = true,
  after = true,
  plan = true,
  project = true,
  phase = true,
  due = true,
  start = true,
  ["repeat"] = true,
  repeat_from = true,
  repeat_after = true,
}
M.NEW_FIELDS = NEW_FIELDS

---The keys of `NEW_FIELDS` that are relations: judged by `edges.validate` before the file is made.
local NEW_RELATIONS = { "after", "plan", "project", "phase" }

-- ── what a front end may write ───────────────────────────────────────────────

-- `has_control` and `too_long` are the contract's own (lib.nvim.contract.ops): a NUL byte, a raw C1 byte and invalid
-- UTF-8 are refused there, and the echo of a refused value is printable. One rule for every front end, not a copy.
local too_long = contract_ops.too_long

---A value over the limits the contract keeps, as a message; nil when it is fine.
---@param key string
---@param value any
---@return string|nil
local function over_limit(key, value)
  local limits = contract.LIMITS
  if key == "title" and too_long(value, limits.title) then
    return ("title is longer than %d characters"):format(limits.title)
  elseif key == "summary" and too_long(value, limits.summary) then
    return ("summary is longer than %d characters"):format(limits.summary)
  elseif type(value) == "table" and value ~= vim.NIL then
    if #value > limits.list_items then
      return ("%s has more than %d entries"):format(key, limits.list_items)
    end
    for _, entry in ipairs(value) do
      if too_long(entry, M.MAX_ENTRY) then
        return ("an entry of %s is longer than %d characters"):format(key, M.MAX_ENTRY)
      end
    end
  elseif too_long(value, M.MAX_ENTRY) and key ~= "title" and key ~= "summary" then
    return ("%s is longer than %d characters"):format(key, M.MAX_ENTRY)
  end
  return nil
end

local has_control = contract_ops.has_control

---The namespaces a ref `<ns>:<key>` may name through the door: what other tools put into `refs:` to find their task again
---(`testing-finding:<fp>` of testing.nvim, `rules-target:<folder>` of rules.nvim; `find` looks them up). A namespace that
---is not listed here is refused like any other colon.
---@type table<string, boolean>
M.REF_NAMESPACES = { ["rules-target"] = true, ["testing-finding"] = true }

---Longest key of a namespaced ref.
M.MAX_NAMESPACE_KEY = 200

---Why a `refs` entry may not be written by a front end that is not the author, or nil: a plain relative path (with an
---optional line or range suffix), a `repo@commit`, an id, or a ref of a registered namespace (`<ns>:<key>`, a key of
---letters, digits and `. _ / -` with no `..` segment). No `..`, no drive or network prefix, no absolute path,
---no control character, no colon but the position suffix.
---@param ref string
---@return string|nil reason
local function bad_ref(ref)
  if ref:find("%c") then
    return "a control character"
  end
  local ns, key = ref:match("^([%a][%w-]*):(.+)$")
  if ns and M.REF_NAMESPACES[ns] then
    if #key > M.MAX_NAMESPACE_KEY or not key:match("^[%w._/-]+$") then
      return "a key of this namespace that is not letters, digits and . _ / -"
    end
    for seg in key:gmatch("[^/]+") do
      if seg == ".." then
        return "a '..' segment"
      end
    end
    if key:match("^/") then
      return "an absolute path"
    end
    return nil
  end
  if ref:match("^%a:") then
    return "a drive prefix"
  end
  if ref:match("^[/\\]") then
    return "an absolute or network path"
  end
  for seg in (ref:gsub("\\", "/")):gmatch("[^/]+") do
    if seg == ".." then
      return "a '..' segment"
    end
  end
  if ref:find(":", 1, true) then
    local path = ref:match("^(.-):%d+:%d+$")
      or ref:match("^(.-):%d+%-%d+$")
      or ref:match("^(.-):%d+$")
    if not path or path:find(":", 1, true) then
      return "a colon that is not a line suffix"
    end
  end
  return nil
end

---@param s string
---@return string
local function clip(s)
  return vim.fn.strchars(s) > 40 and (vim.fn.strcharpart(s, 0, 39) .. "\226\128\166") or s
end

-- ── one operation ────────────────────────────────────────────────────────────

---@class Tasks.OpsCtx
---@field root string
---@field today string
---@field dry boolean
---@field touched table<string, boolean>   # Areas whose index must be written.
---@field claimed table<string, string>   # A dry run: the new id an earlier `move_area` of the request takes -> its old id.
---@field created table<string, Tasks.PendingTask>   # A dry run: the tasks earlier `new` operations would create.
---@field drafts table<string, Tasks.DraftTask>   # A dry run: the files of those tasks, for later operations on them.
---@field files table<string, Tasks.PendingFile>   # A dry run: the plans and projects earlier `plan_new`/`project_new` would create.
---@field attach? Tasks.AttachSourceOpts   # Specs: a fake clipboard; the folders of `attach_dirs` (`api`), never of an operation.

---A failure from `mutate` whose reason has no code: its validation messages are all about the request.
---@param ctx Tasks.OpsCtx
---@param err any
---@param info? table
---@return table
local function mutate_failure(ctx, err, info)
  local entry = fail(ctx, err, info)
  if entry.error.code == "internal" then
    entry.error.code = "invalid_argument"
  end
  if type(info) == "table" and type(info.details) == "table" then
    -- what a front end shows besides the message (a refused phase: `vault.slug_error`)
    local details = vim.tbl_extend("force", entry.error.details or {}, info.details)
    entry.error.details = json.object(details)
  end
  return entry
end

---@param ctx Tasks.OpsCtx
---@param path string
---@return string
local function rel(ctx, path)
  return contract.relative(ctx.root, path) or vim.fs.basename(path)
end

---@param path string
---@return string|nil
local function etag_of_file(path)
  local text = fsio.read(path)
  return text and fsio.etag(text) or nil
end

---The ids earlier operations of a dry run would take (tasks of `new`, plans, projects and paths of `plan_new`,
---`project_new`, `path_new`): one namespace per area, so a later operation does not pick the same slug; nil in a real
---run (the files are on disk by then).
---@param ctx Tasks.OpsCtx
---@return table<string, true>|nil
local function reserved_ids(ctx)
  if not ctx.dry then
    return nil
  end
  local ids = {}
  for _, pending in ipairs({ ctx.created, ctx.files }) do
    for id in pairs(pending) do
      ids[id] = true
    end
  end
  return ids
end

---The resolver of bare `[[slug]]` wikilinks for an operation: in a dry run it also knows the tasks, plans and projects
---earlier operations of the request would create (the real run has made them by then); nil otherwise (the vault's own).
---@param ctx Tasks.OpsCtx
---@return Tasks.LinkResolver|nil
local function link_resolver(ctx)
  if not ctx.dry or (next(ctx.created) == nil and next(ctx.files) == nil) then
    return nil
  end
  local disk = wikilinks.resolver(ctx.root)
  return {
    root = disk.root,
    candidates = function(slug)
      local ids = vim.list_extend({}, disk.candidates(slug))
      for _, pending in ipairs({ ctx.created, ctx.files }) do
        for id, node in pairs(pending) do
          if node.slug == slug and not vim.tbl_contains(ids, id) then
            ids[#ids + 1] = id
          end
        end
      end
      table.sort(ids)
      return ids
    end,
    path = function(id)
      local node = ctx.created[id] or ctx.files[id]
      return node and node.path or disk.path(id)
    end,
  }
end

---The tasks earlier `new` operations of a dry run would create, as files later operations work on; nil in a real run
---(the files are on disk by then).
---@param ctx Tasks.OpsCtx
---@return table<string, Tasks.DraftTask>|nil
local function drafts_of(ctx)
  return ctx.dry and ctx.drafts or nil
end

---Whether `id` names a meeting (`<area>/MEETINGS/<slug>.md`, either form): an id is one file of the area, so a task a
---dry run would create under it is no meeting.
---@param ctx Tasks.OpsCtx
---@param id any
---@return boolean
local function is_meeting(ctx, id)
  if type(id) ~= "string" or (ctx.dry and ctx.drafts[id]) then
    return false
  end
  local area, slug = vault.parse_id(id)
  if not area or not slug or not vault.valid_area(area) or not vault.has_area(ctx.root, area) then
    return false
  end
  -- an occurrence of a series without a file yet is a meeting too: the first change gives it its file
  return vault.resolve_meeting(ctx.root, area, slug) ~= nil
    or require("tasks_nvim.meetings").occurrence(ctx.root, area, slug) ~= nil
end

---Change the text of a task (`mutate.edit_text`) or of a meeting (`meeting_write.edit`, `meeting_transform` when
---given: a meeting has other sections than a task). The result has the same shape; a meeting's says
---`location = "meeting"`.
---@param id string
---@param ctx Tasks.OpsCtx
---@param transform fun(text: string): string|nil, string|nil, any
---@param opts table  # The options of `mutate.edit_text`.
---@param meeting_transform? fun(text: string, meeting: Tasks.Meeting): string|nil, string|nil, any
---@return table|nil
---@return any
---@return table|nil
local function edit_text_of(id, ctx, transform, opts, meeting_transform)
  if is_meeting(ctx, id) then
    local r, err, info =
      require("tasks_nvim.meeting_write").edit(id, meeting_transform or transform, {
        root = ctx.root,
        today = ctx.today,
        if_match = opts.if_match,
        dry_run = ctx.dry,
      })
    if r then
      r.location = "meeting"
    end
    return r, err, info
  end
  return mutate.edit_text(id, transform, opts)
end

---The relations a patch sets, in the shape `edges.validate` takes.
---@param pairs_ table[]
---@return Tasks.EdgeProposal
local function proposal_of(pairs_)
  ---@type Tasks.EdgeProposal
  local proposal = {}
  for _, kv in ipairs(pairs_) do
    local key, value = kv[1], kv[2]
    if key == "blocked_by" or key == "after" then
      proposal[key] = value == vim.NIL and {} or (type(value) == "table" and value or { value })
    elseif key == "plan" or key == "project" or key == "phase" then
      -- `false` removes the relation (`x and false or y` would yield `y`, so spell it out)
      if value == vim.NIL then
        proposal[key] = false
      else
        proposal[key] = value
      end
    end
  end
  return proposal
end

---The routines a write started (`repeat_after`, `routine_after.settle`): their ids join `changed`, their areas are
---indexed with the others. Nil when none started, so a result without one reads as before.
---@param ctx Tasks.OpsCtx
---@param started? { id: string, due: string, after: string }[]
---@param changed string[]
---@return table[]|nil
local function routines_written(ctx, started, changed)
  if type(started) ~= "table" or #started == 0 then
    return nil
  end
  local out = {}
  for _, r in ipairs(started) do
    changed[#changed + 1] = r.id
    local area = r.id:match("^([^/]+)/")
    if area then
      ctx.touched[area] = true
    end
    out[#out + 1] = json.object({ id = r.id, due = r.due, after = r.after })
  end
  return out
end

---A write that took the learning point of its task along (`set` to or from `blocked`, `reopen`): the container is
---one more changed document, and its area's overview may list it.
---@param ctx Tasks.OpsCtx
---@param point { container: string, changed: boolean }|nil
---@param changed string[]
local function point_written(ctx, point, changed)
  if not (point and point.changed) then
    return
  end
  local carea = point.container:match("^([^/]+)/")
  if carea then
    ctx.touched[carea] = true
  end
  changed[#changed + 1] = point.container
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_set(op, ctx)
  local id = op.id
  if id == nil or op.patch == nil then
    return refuse("invalid_argument", "set needs id and patch")
  end
  local resolver = link_resolver(ctx)
  local pairs_, perr, pdetails =
    mutate.check_patch(op.patch, { root = ctx.root, link_resolver = resolver })
  if not pairs_ then
    return refuse("invalid_argument", tostring(perr), pdetails)
  end
  local task, ferr = mutate.find_open(id, ctx.root, drafts_of(ctx))
  if not task then
    -- A reminder and the CI state of the commits may be set and taken away on a finished task (bookkeeping,
    -- `mutate.BOOKKEEPING`); nothing else of it may change.
    local only_bookkeeping = next(op.patch) ~= nil
    for key in pairs(op.patch) do
      if not mutate.BOOKKEEPING[key] then
        only_bookkeeping = false
      end
    end
    task = only_bookkeeping and scan.find_done(id, { root = ctx.root }) or nil
    if not task then
      return fail(ctx, ferr)
    end
  end
  for _, kv in ipairs(pairs_) do
    -- first the characters, then the length: `strchars` cannot take a NUL byte
    if has_control(kv[2]) then
      return refuse("invalid_argument", kv[1] .. " contains a control character")
    end
    local over = over_limit(kv[1], kv[2])
    if over then
      return refuse("payload_too_large", over)
    end
    if kv[1] == "refs" and kv[2] ~= vim.NIL then
      local known = {}
      for _, r in ipairs(task.refs or {}) do
        known[r] = true
      end
      for _, ref in ipairs(kv[2]) do
        local why = not known[ref] and bad_ref(ref)
        if why then
          return refuse("invalid_argument", ("refs: '%s' has %s"):format(clip(ref), why))
        end
      end
    end
  end
  local expect
  if op.expect ~= nil then
    local key = op.expect.key
    if type(key) ~= "string" or not vim.tbl_contains(mutate.SETTABLE, key) then
      return refuse("invalid_argument", "expect.key must be one of the keys set can change")
    end
    local value = op.expect.value
    expect = { key = key, value = value ~= vim.NIL and value or nil }
  end
  local proposal = proposal_of(pairs_)
  if next(proposal) ~= nil then
    local problems, eerr = edges.validate(
      task.id,
      proposal,
      { root = ctx.root, pending = ctx.created, pending_files = ctx.files }
    )
    if not problems then
      return fail(ctx, eerr)
    end
    if #problems > 0 then
      return refuse("invalid_argument", problems[1].message, { problems = problems })
    end
  end
  local r, err, info = mutate.set(id, op.patch, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    expect = expect,
    dry_run = ctx.dry,
    link_resolver = resolver,
    drafts = drafts_of(ctx),
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.changed and not ctx.dry then
    -- the overview of an area lists the open tasks: a finished one is not in it
    if task.location ~= "backlog" then
      ctx.touched[task.area] = true
    end
    entry.inverse = json.object({
      op = "set",
      id = r.id,
      patch = r.before,
      if_match = r.etag_after,
    })
    point_written(ctx, r.point, entry.changed_ids)
  end
  return entry
end

---The answer of an operation that changed the text of one task (`tick_step`, `append_note`).
---@param ctx Tasks.OpsCtx
---@param r table  # What `mutate.edit_text` gave.
---@return table entry
local function text_entry(ctx, r)
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  -- a meeting is in no index of its area
  if r.changed and not ctx.dry and r.location ~= "meeting" then
    ctx.touched[r.area] = true
  end
  return entry
end

---The checkbox section of a meeting `tick_step` and `add_steps` work on (`section`: `agenda`, the default, or
---`followups`); a task takes no `section`.
---@param op table
---@param ctx Tasks.OpsCtx
---@return string|nil key
---@return table|nil refusal
local function item_section(op, ctx)
  if not is_meeting(ctx, op.id) then
    if op.section ~= nil then
      return nil, refuse("invalid_argument", op.op .. ": section belongs to a meeting")
    end
    return nil, nil
  end
  local key = op.section or "agenda"
  if not require("tasks_nvim.meeting_write").ITEM_SECTIONS[key] then
    return nil, refuse("invalid_argument", op.op .. ": section must be agenda or followups")
  end
  return key, nil
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_tick_step(op, ctx)
  if op.id == nil or op.n == nil then
    return refuse("invalid_argument", "tick_step needs id and n")
  end
  local key, refusal = item_section(op, ctx)
  if refusal then
    return refusal
  end
  local done = op.done ~= false
  local mw = require("tasks_nvim.meeting_write")
  local r, err, info = edit_text_of(
    op.id,
    ctx,
    function(text)
      local new_text, step, serr = steps.set_step(text, op.n, done)
      if not new_text then
        return nil, serr
      end
      return new_text, nil, { was = step and step.done or false }
    end,
    {
      root = ctx.root,
      today = ctx.today,
      index = false,
      if_match = op.if_match,
      dry_run = ctx.dry,
      drafts = drafts_of(ctx),
    },
    mw.on_body(function(body)
      local new_body, was = mw.tick_item(body, key or "agenda", op.n, done)
      if not new_body then
        return nil, tostring(was)
      end
      return new_body, nil, { was = was }
    end)
  )
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = text_entry(ctx, r)
  if r.changed and not ctx.dry then
    entry.inverse = json.object({
      op = "tick_step",
      id = r.id,
      n = op.n,
      done = r.extra and r.extra.was or false,
      section = op.section,
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_answer(op, ctx)
  local clear = op.clear == true
  if op.id == nil or op.question == nil or (op.option == nil and not clear) then
    return refuse("invalid_argument", "answer needs id, question and option (or clear)")
  end
  if clear and op.option ~= nil then
    return refuse("invalid_argument", "answer takes an option or clear, not both")
  end
  local r, err, info = mutate.edit_text(op.id, function(text)
    local new_text, was, qerr = questions.answer(text, op.question, clear and 0 or op.option)
    if not new_text then
      return nil, qerr
    end
    return new_text, nil, { was = was and was.was or 0, key = was and was.key or op.question }
  end, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    dry_run = ctx.dry,
    drafts = drafts_of(ctx),
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = text_entry(ctx, r)
  if r.changed and not ctx.dry then
    -- Taking the answer back: the option that was ticked, or `clear` when none was; the key is the one the question
    -- has now.
    local was = r.extra and r.extra.was or 0
    entry.inverse = json.object({
      op = "answer",
      id = r.id,
      question = r.extra and r.extra.key or op.question,
      option = was > 0 and was or nil,
      clear = was == 0 or nil,
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_reopen(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "reopen needs id")
  end
  local r, err, info = mutate.reopen(op.id, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    status = op.status,
    if_match = op.if_match,
    dry_run = ctx.dry,
    drafts = drafts_of(ctx),
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.path and r.changed then
    entry.file = rel(ctx, r.path)
  end
  if #r.notes > 0 then
    entry.notes = r.notes
  end
  if r.changed and not ctx.dry then
    ctx.touched[r.area] = true
    point_written(ctx, r.point, entry.changed_ids)
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_append_note(op, ctx)
  if op.id == nil or op.text == nil then
    return refuse("invalid_argument", "append_note needs id and text")
  end
  -- the steps module refuses what is not one line; the rest of what a front end may not write is judged here, as for
  -- every other text (the 8-bit controls and the Unicode line separators end a line in other tools)
  if has_control(op.text) then
    return refuse("invalid_argument", "text contains a control character")
  end
  local mw = require("tasks_nvim.meeting_write")
  local r, err, info = edit_text_of(
    op.id,
    ctx,
    function(text)
      return steps.add_note(text, op.text, ctx.today)
    end,
    {
      root = ctx.root,
      today = ctx.today,
      index = false,
      if_match = op.if_match,
      dry_run = ctx.dry,
      drafts = drafts_of(ctx),
    },
    mw.on_body(function(body)
      -- a meeting's notes are its minutes: one line with the time, as a capture of text writes it
      if op.text:find("[\r\n]") or vim.trim(op.text) == "" then
        return nil, "a note is one line of text"
      end
      return mw.capture_body(
        body,
        { kind = "text", text = op.text, at = tostring(os.date("%H:%M")) }
      )
    end)
  )
  if not r then
    return mutate_failure(ctx, err, info)
  end
  return text_entry(ctx, r)
end

---The answer of an operation that changed the text below the frontmatter (`set_body`, `add_steps`): the way back is
---a `set_body` with the old text (`r.extra.old`); none when it could not be sent again (too long, a control character).
---@param ctx Tasks.OpsCtx
---@param r table  # What `mutate.edit_text` gave.
---@return table entry
local function body_entry(ctx, r)
  local entry = text_entry(ctx, r)
  local old = r.extra and r.extra.old
  if
    r.changed
    and not ctx.dry
    and type(old) == "string"
    and not has_control(old)
    and not too_long(old, M.MAX_SET_BODY)
  then
    entry.inverse = json.object({
      op = "set_body",
      id = r.id,
      body = old,
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_set_body(op, ctx)
  if op.id == nil or op.body == nil then
    return refuse("invalid_argument", "set_body needs id and body")
  end
  if has_control(op.body) then
    return refuse("invalid_argument", "body contains a control character")
  end
  if too_long(op.body, M.MAX_SET_BODY) then
    return refuse("payload_too_large", ("body is longer than %d characters"):format(M.MAX_SET_BODY))
  end
  local r, err, info = edit_text_of(op.id, ctx, function(text)
    local parsed = fm.parse(text)
    if not parsed or not parsed.has_block or parsed.unterminated then
      return nil, "the file has no frontmatter block to write below"
    end
    local old = fsio.lf(parsed.body)
    local trimmed = vim.trim(fsio.lf(op.body))
    local new_body = "\n" .. (trimmed ~= "" and (trimmed .. "\n") or "")
    if parsed.eol == "\r\n" then
      new_body = new_body:gsub("\n", "\r\n")
    end
    parsed.body = new_body
    return fm.serialize(parsed), nil, { old = old }
  end, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    dry_run = ctx.dry,
    drafts = drafts_of(ctx),
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  return body_entry(ctx, r)
end

---`set_section`: set the section `heading` (`## ...`) of a task's body to `text`, replacing a section of that heading
---(up to the next `## ` heading) or adding it at the end; on an open task or a finished one in `Backlog/` (a review of
---a finished task, `:Tasks agent kind=review-done`). The frontmatter stays but for `updated`; the file keeps its line
---ending. The inverse sets the old text again when there was a section of that heading.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_set_section(op, ctx)
  if op.id == nil or op.heading == nil or op.text == nil then
    return refuse("invalid_argument", "set_section needs id, heading and text")
  end
  local heading = op.heading
  -- has_control lets the line break and the tab through (a body has them); a heading is one line.
  if
    not heading:match("^## %S")
    or #heading > 200
    or heading:find("[\r\n\t]")
    or has_control(heading)
  then
    return refuse(
      "invalid_argument",
      "heading is one line of at most 200 characters that starts with '## ' and a word"
    )
  end
  if has_control(op.text) then
    return refuse("invalid_argument", "text contains a control character")
  end
  if too_long(op.text, M.MAX_SECTION) then
    return refuse("payload_too_large", ("text is longer than %d characters"):format(M.MAX_SECTION))
  end
  local text = vim.trim(fsio.lf(op.text))
  if text == "" then
    return refuse("invalid_argument", "text is empty")
  end
  -- A second section of the task's level would take the place of the task's own (and stay behind the next time).
  if ("\n" .. text):find("\n## ") then
    return refuse(
      "invalid_argument",
      "text holds a '## ' heading; only deeper headings (###) belong to a section"
    )
  end
  local r, err, info = edit_text_of(op.id, ctx, function(file_text)
    local parsed = fm.parse(file_text)
    if not parsed or not parsed.has_block or parsed.unterminated then
      return nil, "the file has no frontmatter block to write below"
    end
    local body = fsio.lf(parsed.body)
    local old = sections.get(body, heading)
    -- One blank line below the frontmatter; only blank lines go, the first line of the text keeps its indent.
    -- (`sections.set` ends with one line break.)
    local new_body = "\n" .. sections.set(body, heading .. "\n\n" .. text):gsub("^%s*\n", "")
    if parsed.eol == "\r\n" then
      new_body = new_body:gsub("\n", "\r\n")
    end
    parsed.body = new_body
    return fm.serialize(parsed), nil, { old = old }
  end, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    dry_run = ctx.dry,
    drafts = drafts_of(ctx),
    allow_done = true,
  })
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = text_entry(ctx, r)
  if r.location == "backlog" then
    -- a finished task is in no index: nothing for the door to write
    ctx.touched[r.area] = nil
  end
  local old = r.extra and r.extra.old
  if
    r.changed
    and not ctx.dry
    and old
    and old ~= ""
    and not too_long(old, M.MAX_SECTION)
    and not has_control(old)
  then
    entry.inverse = json.object({
      op = "set_section",
      id = r.id,
      heading = heading,
      text = old,
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_add_steps(op, ctx)
  if op.id == nil or op.steps == nil then
    return refuse("invalid_argument", "add_steps needs id and steps")
  end
  local items = type(op.steps) == "string" and { op.steps } or op.steps
  if #items > contract.LIMITS.list_items then
    return refuse(
      "invalid_argument",
      ("steps has more than %d entries"):format(contract.LIMITS.list_items)
    )
  end
  -- the steps module refuses what is not one line; the 8-bit controls, the Unicode line separators and broken UTF-8
  -- are judged here, as for every other text
  if has_control(items) then
    return refuse("invalid_argument", "steps contains a control character")
  end
  local key, refusal = item_section(op, ctx)
  if refusal then
    return refusal
  end
  local mw = require("tasks_nvim.meeting_write")
  local r, err, info = edit_text_of(
    op.id,
    ctx,
    function(text)
      local new_text, serr = steps.add_steps(text, items)
      if not new_text then
        return nil, serr
      end
      local parsed = fm.parse(text)
      return new_text, nil, { old = parsed and parsed.has_block and fsio.lf(parsed.body) or nil }
    end,
    {
      root = ctx.root,
      today = ctx.today,
      index = false,
      if_match = op.if_match,
      dry_run = ctx.dry,
      drafts = drafts_of(ctx),
    },
    mw.on_body(function(body)
      local new_body, aerr = mw.add_items(body, key or "agenda", items)
      if not new_body then
        return nil, aerr
      end
      return new_body, nil, { old = fsio.lf(body) }
    end)
  )
  if not r then
    return mutate_failure(ctx, err, info)
  end
  return body_entry(ctx, r)
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_new(op, ctx)
  if op.area == nil or op.title == nil then
    return refuse("invalid_argument", "new needs area and title")
  end
  local fields = {}
  for key, value in pairs(op.fields or {}) do
    if not NEW_FIELDS[key] then
      return refuse(
        "invalid_argument",
        ("fields: unknown field '%s' (fields: %s)"):format(tostring(key), sorted_names(NEW_FIELDS))
      )
    end
    if value ~= vim.NIL then
      fields[key] = value
    end
  end
  -- first the characters, then the length: `strchars` cannot take a NUL byte
  if has_control(op.area) then
    return refuse("invalid_argument", "area contains a control character")
  end
  if has_control(op.title) then
    return refuse("invalid_argument", "title contains a control character")
  end
  for key, value in pairs(fields) do
    if has_control(value) then
      return refuse("invalid_argument", key .. " contains a control character")
    end
  end
  if op.body ~= nil and has_control(op.body) then
    return refuse("invalid_argument", "body contains a control character")
  end
  local over = over_limit("title", op.title)
  if too_long(op.body, M.MAX_BODY) then
    over = ("body is longer than %d characters"):format(M.MAX_BODY)
  end
  for key, value in pairs(fields) do
    over = over or over_limit(key, value)
  end
  if over then
    return refuse("payload_too_large", over)
  end
  if type(fields.refs) == "table" then
    for _, ref in ipairs(fields.refs) do
      local why = type(ref) == "string" and bad_ref(ref)
      if why then
        return refuse("invalid_argument", ("refs: '%s' has %s"):format(clip(ref), why))
      end
    end
  end
  -- `links` of the request is the frontmatter field; in `mutate.new` that name is the wikilink mode
  local new_opts = vim.tbl_extend("force", fields, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    title = op.title,
    body = op.body,
    dry_run = ctx.dry,
    -- a dry run: the ids and slugs earlier `new` ops of the request take, as the real run has them on disk by then
    reserved = reserved_ids(ctx),
    link_resolver = link_resolver(ctx),
    relations_judged = true,
  })
  new_opts.web_links, new_opts.links = fields.links, nil
  -- `repeat` is a word of Lua: `mutate.new` calls the field `repeat_every`
  new_opts.repeat_every, new_opts["repeat"] = fields["repeat"], nil
  -- the relations, as `set` judges them: on the ids the values name (wikilinks resolved), before anything is written
  local relation = {}
  for _, key in ipairs(NEW_RELATIONS) do
    relation[key] = fields[key]
  end
  local proposal = {}
  if next(relation) ~= nil then
    local pairs_, perr, pdetails =
      mutate.check_patch(relation, { root = ctx.root, link_resolver = new_opts.link_resolver })
    if not pairs_ then
      return refuse("invalid_argument", tostring(perr), pdetails)
    end
    proposal = proposal_of(pairs_)
    -- the id the task will get: an open task may wait on it already, and a stage gate can close a circle through it
    local would, werr, winfo =
      mutate.new(op.area, vim.tbl_extend("force", new_opts, { dry_run = true }))
    if not would then
      return mutate_failure(ctx, werr, winfo)
    end
    local problems, eerr = edges.validate(would.id, proposal, {
      root = ctx.root,
      new = true,
      pending = ctx.created,
      pending_files = ctx.files,
    })
    if not problems then
      return fail(ctx, eerr)
    end
    if #problems > 0 then
      return refuse("invalid_argument", problems[1].message, { problems = problems })
    end
  end
  local r, err, info = mutate.new(op.area, new_opts)
  if not r then
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_create" or "created",
    file = rel(ctx, r.path),
    changed_ids = ctx.dry and {} or { r.id },
  }
  if ctx.dry then
    -- the real run creates it before the next operation runs: a later relation to it is not dangling, its slug is
    -- taken, and its own relations are edges of the graph a later circle check walks
    ctx.drafts[r.id] = { path = r.path, text = r.text, folder = r.folder }
    ctx.created[r.id] = {
      id = r.id,
      slug = r.slug,
      path = r.area .. "/ROADMAP/tasks/" .. (r.folder and (r.slug .. "/") or "") .. r.slug,
      status = type(fields.status) == "string" and fields.status or "open",
      blocked_by = {},
      after = proposal.after,
      plan = proposal.plan or nil,
      project = proposal.project or nil,
      phase = proposal.phase or nil,
    }
  else
    ctx.touched[r.area] = true
    entry.etag_after = etag_of_file(r.path)
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_reorder(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "reorder needs id")
  end
  local r, err, info = batch.reorder(op.id, {
    after = op.after,
    before = op.before,
    group = op.group,
    if_match = op.if_match,
  }, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    dry_run = ctx.dry,
    drafts = drafts_of(ctx),
  })
  if not r then
    return fail(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    group = r.group,
    renumbered = r.renumbered,
    writes = #r.writes,
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = ctx.dry and {} or r.changed_ids,
  }
  if r.changed and not ctx.dry then
    for _, area in ipairs(r.areas) do
      ctx.touched[area] = true
    end
    entry.inverse = json.object({
      op = "reorder",
      id = r.id,
      after = r.inverse and r.inverse.after,
      before = r.inverse and r.inverse.before,
      if_match = r.etag_after,
    })
    -- The way back that puts the moved task behind its old neighbour restores the place, not the numbers: a task
    -- that had no `order` keeps one, and the neighbours the move numbered stay numbered. `restore` gives every file
    -- the move wrote its old `order` back (also a single one).
    if #r.restore > 0 then
      local restore = {}
      for _, w in ipairs(r.restore) do
        restore[#restore + 1] = json.object({
          op = "set",
          id = w.id,
          patch = json.object({ order = w.was ~= nil and batch.order_text(w.was) or vim.NIL }),
          if_match = w.etag_after,
        })
      end
      entry.restore = json.array(restore)
    end
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_done(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "done needs id")
  end
  if op.outcome ~= nil and not model.is_outcome(op.outcome) then
    return refuse(
      "invalid_argument",
      ("unknown outcome '%s' (expected %s)"):format(
        tostring(op.outcome),
        table.concat(model.OUTCOMES, ", ")
      )
    )
  end
  if has_control(op.outcome_reason) then
    return refuse("invalid_argument", "outcome_reason contains a control character")
  end
  if op.ci ~= nil and not model.is_ci(op.ci) then
    return refuse(
      "invalid_argument",
      ("unknown ci '%s' (expected %s)"):format(tostring(op.ci), table.concat(model.CI_STATES, ", "))
    )
  end
  if ctx.dry then
    local pv, err, info = done_flow.preview(op.id, {
      root = ctx.root,
      today = ctx.today,
      drafts = ctx.drafts,
      outcome = op.outcome,
      outcome_reason = op.outcome_reason,
    })
    if not pv then
      return fail(ctx, err, info)
    end
    return {
      ok = true,
      id = pv.id,
      outcome = pv.already and "unchanged" or "would_done",
      to = rel(ctx, pv.to),
      etag_before = pv.etag,
      changed_ids = {},
    }
  end
  if op.confirm == nil then
    return refuse(
      "invalid_argument",
      "done needs the confirm token of done_preview for the version of the task that was shown"
    )
  end
  local etag = mutate.confirm_etag(op.id, op.confirm)
  if not etag then
    return refuse("invalid_argument", "the confirm token is not one for " .. op.id)
  end
  if has_control(op.done_in) then
    return refuse("invalid_argument", "done_in contains a control character")
  end
  if has_control(op.commits) then
    return refuse("invalid_argument", "commits contains a control character")
  end
  if op.remind ~= nil then
    local _, rerr = model.resolve_remind(op.remind, ctx.today)
    if rerr then
      return refuse("invalid_argument", rerr)
    end
  end
  local flow, err, info = done_flow.run(op.id, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = etag,
    done_in = op.done_in,
    commits = op.commits,
    remind = op.remind,
    outcome = op.outcome,
    outcome_reason = op.outcome_reason,
    ci = op.ci,
    ack = op.ack == true,
    pick_next = false,
  })
  if not flow then
    return fail(ctx, err, info)
  end
  local done = flow.done
  if flow.point and flow.point.changed then
    -- the container of the learning point was written too
    local cid = flow.point.container
    local carea = cid:match("^([^/]+)/")
    if carea then
      ctx.touched[carea] = true
    end
  end
  local area = done.area
  if area and not done.already then
    ctx.touched[area] = true
  end
  local changed = { done.id }
  for _, plan_id in ipairs(flow.plans_closed) do
    changed[#changed + 1] = plan_id
  end
  for _, project_id in ipairs(flow.projects_closed) do
    changed[#changed + 1] = project_id
  end
  if flow.point and flow.point.changed then
    changed[#changed + 1] = flow.point.container
  end
  vim.list_extend(changed, flow.milestones_reached)
  vim.list_extend(changed, flow.milestones_reopened)
  local routines = routines_written(ctx, flow.routines_started, changed)
  local notes = {}
  for _, note in ipairs(flow.notes) do
    notes[#notes + 1] = contract.redact(ctx.root, note)
  end
  return {
    ok = true,
    id = done.id,
    outcome = done.already and "unchanged" or "done",
    to = done.to and rel(ctx, done.to) or nil,
    etag_before = etag,
    steps_ticked = flow.steps_ticked,
    plans_closed = flow.plans_closed,
    projects_closed = flow.projects_closed,
    -- capability `milestones`: only when the finish reached or opened one
    milestones_reached = #flow.milestones_reached > 0 and flow.milestones_reached or nil,
    milestones_reopened = #flow.milestones_reopened > 0 and flow.milestones_reopened or nil,
    -- capability `repeat_steps`: the routines that waited for this task (`repeat_after`) and start now
    routines_started = routines,
    -- the learning point the task was promoted from, set to the finish's state (capability `outcome`)
    point = flow.point and {
      container = flow.point.container,
      key = flow.point.key,
      state = flow.point.state,
      changed = flow.point.changed,
      held = flow.point.held or nil,
    } or nil,
    notes = notes,
    changed_ids = done.already and {} or changed,
  }
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_move_area(op, ctx)
  if op.id == nil or op.to_area == nil then
    return refuse("invalid_argument", "move_area needs id and to_area")
  end
  if not ctx.dry then
    local r, err, info = moves.move(op.id, op.to_area, {
      root = ctx.root,
      today = ctx.today,
      index = false,
      if_match = op.if_match,
    })
    if not r then
      return mutate_failure(ctx, err, info)
    end
    ctx.touched[r.from_area] = true
    ctx.touched[r.area] = true
    local changed = { r.id, r.new_id }
    local rewritten = {}
    for _, w in ipairs(r.rewritten) do
      changed[#changed + 1] = w.id
      rewritten[#rewritten + 1] = { kind = w.kind, id = w.id }
    end
    local entry = {
      ok = true,
      id = r.id,
      outcome = "moved",
      new_id = r.new_id,
      etag_after = r.etag_after,
      etag_before = r.etag_before,
      file = rel(ctx, r.to),
      rewritten = rewritten,
      changed_ids = changed,
      inverse = json.object({
        op = "move_area",
        id = r.new_id,
        to_area = r.from_area,
        if_match = r.etag_after,
      }),
    }
    if #r.notes > 0 then
      entry.notes = r.notes
    end
    return entry
  end
  local report, err, info =
    moves.preview(op.id, op.to_area, { root = ctx.root, drafts = drafts_of(ctx) })
  if not report then
    return fail(ctx, err, info)
  end
  -- a dry run sees the disk, not the earlier moves of the request: the real run makes them one after the other, so a
  -- target that an earlier move of this request takes is taken (the second move would be refused as "open task already")
  if report.ok then
    local first = ctx.claimed[report.new_id]
    if first then
      report.ok = false
      report.conflicts[#report.conflicts + 1] = {
        code = "slug-taken",
        message = ("%s is the target of another move of this request (%s)"):format(
          report.new_id,
          first
        ),
      }
    else
      ctx.claimed[report.new_id] = op.id
    end
  end
  local conflicts = {}
  for _, c in ipairs(report.conflicts) do
    conflicts[#conflicts + 1] = { code = c.code, message = c.message }
  end
  local references = {}
  for _, ref in ipairs(report.references) do
    references[#references + 1] = {
      kind = ref.kind,
      id = ref.id,
      path = ref.path and rel(ctx, ref.path) or nil,
    }
  end
  return {
    ok = report.ok,
    id = report.id,
    outcome = report.ok and "would_move" or "blocked",
    move = json.object({
      new_id = report.new_id,
      to_area = report.to_area,
      from = rel(ctx, report.from),
      to = rel(ctx, report.to),
      folder = report.folder,
      conflicts = conflicts,
      references = references,
      notes = report.notes,
    }),
    changed_ids = {},
  }
end

---Make a plan file or a project file (`kind`).
---@param op table
---@param ctx Tasks.OpsCtx
---@param kind "plan"|"project"
---@return table entry
local function new_file(op, ctx, kind)
  local name = kind .. "_new"
  if op.area == nil or op.title == nil then
    return refuse("invalid_argument", name .. " needs area and title")
  end
  for _, key in ipairs({
    "area",
    "title",
    "summary",
    "slug",
    "target",
    "gate",
    "status",
    "areas",
    "phases",
    "project",
    "phase",
    "icon",
    "cover",
    "template",
    "requires",
    "requires_gate",
  }) do
    if has_control(op[key]) then
      return refuse("invalid_argument", key .. " contains a control character")
    end
  end
  local over = over_limit("title", op.title)
    or over_limit("area", op.area)
    or (op.slug and over_limit("slug", op.slug))
    or (op.target and over_limit("target", op.target))
    or (op.summary and over_limit("summary", op.summary))
    or (op.areas and over_limit("areas", op.areas))
    or (op.phases and over_limit("phases", op.phases))
    or (op.requires and over_limit("requires", op.requires))
  if over then
    return refuse("payload_too_large", over)
  end
  if type(op.summary) == "string" and op.summary:find("[\r\n]") then
    return refuse("invalid_argument", "summary must be one line")
  end
  local r, err, info = require("tasks_nvim.plans").new(op.area, {
    root = ctx.root,
    today = ctx.today,
    kind = kind,
    title = op.title,
    areas = op.areas,
    target = op.target,
    phases = op.phases,
    gate = op.gate,
    status = op.status,
    summary = op.summary,
    slug = op.slug,
    project = op.project,
    phase = op.phase,
    web_links = op.links,
    icon = op.icon,
    cover = op.cover,
    template = op.template,
    requires = op.requires,
    requires_gate = op.requires_gate,
    dry_run = ctx.dry,
    pending_files = ctx.dry and ctx.files or nil,
    -- the ids earlier operations of the request take: a second plan of the same title gets `-2`, as in the real run
    reserved = reserved_ids(ctx),
    link_resolver = link_resolver(ctx),
  })
  if not r then
    if info and info.code == "invalid_argument" then
      return refuse(
        "invalid_argument",
        tostring(err),
        info.problems and { problems = info.problems } or info.details
      )
    end
    return mutate_failure(ctx, err, info)
  end
  if ctx.dry then
    -- the real run has the file on disk before the next operation: a later `plan`, `project` or `phase` may name it
    local folder = kind == "project" and "projects" or (kind == "path" and "paths" or "plans")
    ctx.files[r.id] = {
      id = r.id,
      kind = kind,
      slug = r.slug,
      path = op.area .. "/ROADMAP/" .. folder .. "/" .. r.slug,
      phase_order = r.phase_order or {},
    }
  end
  return {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_create" or "created",
    file = rel(ctx, r.path),
    slug = r.slug,
    renamed = r.renamed,
    changed_ids = ctx.dry and {} or { r.id },
  }
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_plan_new(op, ctx)
  return new_file(op, ctx, "plan")
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_project_new(op, ctx)
  return new_file(op, ctx, "project")
end

---Change the frontmatter of a plan file, a project file or a learning path (`kind`).
---@param op table
---@param ctx Tasks.OpsCtx
---@param kind "plan"|"project"|"path"
---@return table entry
local function set_file(op, ctx, kind)
  local name = kind .. "_set"
  if op.id == nil or op.patch == nil then
    return refuse("invalid_argument", name .. " needs id and patch")
  end
  for key, value in pairs(op.patch) do
    if has_control(key) or has_control(value) then
      return refuse("invalid_argument", "the patch contains a control character")
    end
    local over = over_limit(key, value)
    if over then
      return refuse("payload_too_large", over)
    end
  end
  local r, err, info = require("tasks_nvim.plans").set(op.id, op.patch, {
    root = ctx.root,
    today = ctx.today,
    kind = kind,
    if_match = op.if_match,
    dry_run = ctx.dry,
    link_resolver = link_resolver(ctx),
  })
  if not r then
    if info and info.code == "invalid_argument" then
      return refuse(
        "invalid_argument",
        tostring(err),
        info.problems and { problems = info.problems } or info.details
      )
    end
    if info and info.code == "not_found" then
      return refuse("not_found", tostring(err))
    end
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.changed and not ctx.dry then
    entry.inverse = json.object({
      op = name,
      id = r.id,
      patch = json.object(r.before),
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_plan_set(op, ctx)
  return set_file(op, ctx, "plan")
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_project_set(op, ctx)
  return set_file(op, ctx, "project")
end

---Finish a plan (`plan_close`, then the project it belonged to when it was the last) or a project by hand.
---@param op table
---@param ctx Tasks.OpsCtx
---@param kind "plan"|"project"
---@return table entry
local function close_file(op, ctx, kind)
  local name = kind .. "_close"
  if op.id == nil then
    return refuse("invalid_argument", name .. " needs id")
  end
  local opts = { root = ctx.root, today = ctx.today, date = ctx.today, dry_run = ctx.dry }
  local plans_closed, projects_closed, notes = {}, {}, {}
  if kind == "plan" then
    local file, ferr = require("tasks_nvim.plans").find(op.id, { root = ctx.root })
    if not file then
      local held = scan.find_done(op.id, { root = ctx.root })
      if held and require("tasks_nvim.projects").finished_kind(held) == "plan" then
        return { ok = true, id = op.id, outcome = "unchanged", changed_ids = {} }
      end
      return refuse("not_found", tostring(ferr))
    end
    local res = done_flow.close_plans({ op.id }, opts)
    if #res.closed == 0 then
      local holding = res.refused[op.id]
      if holding then
        return refuse(
          "invalid_argument",
          ("%s still has %d open task%s"):format(op.id, #holding, #holding == 1 and "" or "s"),
          { holding = holding }
        )
      end
      return refuse("internal", tostring(res.notes[1] or (op.id .. " was not closed")))
    end
    plans_closed = res.closed
    vim.list_extend(notes, res.notes)
    if not ctx.dry then
      local project_ids = {}
      for _, plan_id in ipairs(res.closed) do
        project_ids[#project_ids + 1] = res.projects[plan_id]
      end
      local pres = done_flow.close_projects(project_ids, opts)
      projects_closed = pres.closed
      vim.list_extend(notes, pres.notes)
      done_flow.refresh_marker_docs({ root = ctx.root, closed = res.summaries })
    end
  else
    local file, ferr = require("tasks_nvim.projects").find(op.id, { root = ctx.root })
    if not file then
      local held = scan.find_done(op.id, { root = ctx.root })
      if held and require("tasks_nvim.projects").finished_kind(held) == "project" then
        return { ok = true, id = op.id, outcome = "unchanged", changed_ids = {} }
      end
      return refuse("not_found", tostring(ferr))
    end
    local res = done_flow.close_projects({ op.id }, opts)
    if #res.closed == 0 then
      local holding = res.refused[op.id]
      local waiting = res.waiting and res.waiting[op.id]
      if waiting then
        return refuse(
          "invalid_argument",
          ("%s waits for %s (requires_gate: hard): finish that first"):format(
            op.id,
            table.concat(waiting, ", ")
          ),
          {
            holding = waiting,
            waiting_on = vim.tbl_map(function(id)
              return json.object({ id = id })
            end, waiting),
          }
        )
      end
      if holding then
        return refuse(
          "invalid_argument",
          ("%s still has %d open task%s, plan%s or learning path%s"):format(
            op.id,
            #holding,
            #holding == 1 and "" or "s",
            #holding == 1 and "" or "s",
            #holding == 1 and "" or "s"
          ),
          { holding = holding }
        )
      end
      return refuse("internal", tostring(res.notes[1] or (op.id .. " was not closed")))
    end
    projects_closed = res.closed
    vim.list_extend(notes, res.notes)
  end
  local changed = {}
  if not ctx.dry then
    vim.list_extend(changed, plans_closed)
    vim.list_extend(changed, projects_closed)
  end
  local redacted = {}
  for _, note in ipairs(notes) do
    redacted[#redacted + 1] = contract.redact(ctx.root, note)
  end
  return {
    ok = true,
    id = op.id,
    outcome = ctx.dry and "would_close" or "closed",
    plans_closed = plans_closed,
    projects_closed = projects_closed,
    notes = redacted,
    changed_ids = changed,
  }
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_plan_close(op, ctx)
  return close_file(op, ctx, "plan")
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_project_close(op, ctx)
  return close_file(op, ctx, "project")
end

-- ── learning paths ───────────────────────────────────────────────────────────

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_path_new(op, ctx)
  -- a path has no stages: `phases`, `gate` and `phase` are no fields of `path_new` (the request is refused)
  return new_file(op, ctx, "path")
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_path_set(op, ctx)
  return set_file(op, ctx, "path")
end

---Finish a learning path by hand (moved to `Backlog/FEATURES/` with `closed_kind: path`). A path finished already is
---`unchanged`; a dry run only says that it would be.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_path_close(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "path_close needs id")
  end
  local paths = require("tasks_nvim.paths")
  local file, ferr = paths.find(op.id, { root = ctx.root })
  if not file then
    local held = scan.find_done(op.id, { root = ctx.root })
    if held and require("tasks_nvim.projects").finished_kind(held) == "path" then
      return { ok = true, id = op.id, outcome = "unchanged", changed_ids = {} }
    end
    return refuse("not_found", tostring(ferr))
  end
  -- what the path builds on (`requires`): a hard gate refuses, in a dry run too
  local gerr, ginfo = paths.close_gate(file, ctx.root)
  if gerr then
    return refuse("invalid_argument", contract.redact(ctx.root, gerr), {
      holding = ginfo and ginfo.waiting_on or {},
      waiting_on = vim.tbl_map(function(w)
        return json.object({ id = w.id, via = w.via })
      end, ginfo and ginfo.waiting or {}),
    })
  end
  if ctx.dry then
    return { ok = true, id = op.id, outcome = "would_close", changed_ids = {} }
  end
  local r, err =
    paths.close(op.id, { root = ctx.root, today = ctx.today, date = ctx.today, index = false })
  if not r then
    return mutate_failure(ctx, err, nil)
  end
  ctx.touched[file.area] = true
  local changed = { op.id }
  -- a soft requirement not finished yet, a routine that could not start: said, never refused
  local notes = {}
  for _, note in ipairs(r.notes or {}) do
    notes[#notes + 1] = contract.redact(ctx.root, tostring(note))
  end
  return {
    ok = true,
    id = op.id,
    outcome = "closed",
    to = rel(ctx, r.to),
    routines_started = routines_written(ctx, r.routines_started, changed),
    notes = #notes > 0 and notes or nil,
    changed_ids = changed,
  }
end

---The reference of a learning point in an operation: its key (`syntax`, `#syntax`) or its position `#3`.
---@param point any
---@return string|integer|nil
local function point_ref(point)
  if type(point) ~= "string" or point == "" then
    return nil
  end
  local n = point:match("^#(%d+)$")
  return n and tonumber(n) or point:gsub("^#", "")
end

---Change one learning point of an open path: its state and reason, its XP (`xp`, or `xp_clear` to remove them) and/or
---its note (`paths.point`); the answer carries the progress after it and an `inverse` (what the op touched, as it was
---before; a note the point did not have is "", XP it did not have are `xp_clear`).
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_node_set(op, ctx)
  local ref = point_ref(op.point)
  local touches_xp = op.xp ~= nil or op.xp_clear == true
  if op.id == nil or ref == nil or (op.state == nil and op.note == nil and not touches_xp) then
    return refuse("invalid_argument", "node_set needs id, point and a state, a note or xp")
  end
  if op.xp ~= nil and op.xp_clear == true then
    return refuse("invalid_argument", "node_set takes xp or xp_clear, not both")
  end
  if has_control(op.reason) then
    return refuse("invalid_argument", "reason contains a control character")
  end
  if has_control(op.note) then
    return refuse("invalid_argument", "note contains a control character")
  end
  local paths = require("tasks_nvim.paths")
  local before = paths.find(op.id, { root = ctx.root })
  local old
  if before and before.tree then
    local n = require("tasks_nvim.lernbaum").node(before.tree, ref)
    old = n and { state = n.state, reason = n.reason, note = n.note, xp = n.xp_own } or nil
    if old then
      old.safety = n.safety_eff ~= nil
    end
  end
  local xp
  if op.xp ~= nil then
    xp = op.xp
  elseif op.xp_clear == true then
    xp = ""
  end
  local r, err, info = paths.point(op.id, ref, op.state, op.reason, {
    root = ctx.root,
    today = ctx.today,
    index = false,
    if_match = op.if_match,
    dry_run = ctx.dry,
    note = op.note,
    xp = xp,
    ack = op.ack == true,
  })
  if not r then
    if info and (info.code == "invalid_argument" or info.code == "not_found") then
      return refuse(info.code, contract.redact(ctx.root, tostring(err)))
    end
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    node = json.object({
      line = r.node.line,
      key = r.node.key,
      state = r.node.state,
      xp = touches_xp and r.node.xp or nil,
    }),
    progress = json.object(r.progress),
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  entry.routines_started = routines_written(ctx, r.routines_started, entry.changed_ids)
  -- the inverse gives back what the op touched: the state and reason the point had, its note ("" when it had none)
  if r.changed and not ctx.dry and old and (op.state == nil or old.state) then
    entry.inverse = json.object({
      op = "node_set",
      id = r.id,
      point = r.node.key or ("#" .. tostring(ref)),
      state = op.state ~= nil and old.state or nil,
      reason = op.state ~= nil and old.reason or nil,
      note = op.note ~= nil and (old.note or "") or nil,
      xp = touches_xp and old.xp or nil,
      xp_clear = (touches_xp and old.xp == nil) or nil,
      -- the point was closed under `{safety}` before: giving that back was read once already
      ack = (op.state ~= nil and old.safety and (old.state == "learned" or old.state == "seen"))
        or nil,
      if_match = r.etag_after,
    })
  end
  return entry
end

---Mark the reward of a level of a path granted or not (`paths.set_reward`): `level` is the number of the level (`"1"`)
---or `"done"` for the whole path. The inverse gives the mark back.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_path_reward(op, ctx)
  if op.id == nil or op.level == nil or op.given == nil then
    return refuse("invalid_argument", "path_reward needs id, level and given")
  end
  if has_control(op.level) then
    return refuse("invalid_argument", "level contains a control character")
  end
  local r, err, info = require("tasks_nvim.paths").set_reward(op.id, op.level, op.given, {
    root = ctx.root,
    today = ctx.today,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    if info and (info.code == "invalid_argument" or info.code == "not_found") then
      return refuse(info.code, contract.redact(ctx.root, tostring(err)))
    end
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    level = json.object({ ref = r.level.ref, line = r.level.line, given = r.level.given }),
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.changed and not ctx.dry then
    entry.inverse = json.object({
      op = "path_reward",
      id = r.id,
      level = r.level.ref,
      given = r.level.before,
      if_match = r.etag_after,
    })
  end
  return entry
end

---Write the levels of a path, its `## Level` section (`paths.set_levels`): `levels` is `{ list, done? }`. The inverse
---carries the levels the section had (none when it held lines a spec cannot carry).
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_path_levels(op, ctx)
  if op.id == nil or op.levels == nil then
    return refuse("invalid_argument", "path_levels needs id and levels")
  end
  -- the door looks into the lists of an operation, not into its objects: the texts of the levels are checked here as
  -- every other text is (C1, a line separator, broken UTF-8; `lernlevel.render` sees only C0 and DEL)
  if type(op.levels) == "table" then
    local texts = {}
    for _, l in ipairs(type(op.levels.list) == "table" and op.levels.list or {}) do
      if type(l) == "table" then
        for _, key in ipairs({ "name", "badge", "reward" }) do
          texts[#texts + 1] = l[key]
        end
      end
    end
    if type(op.levels.done) == "table" then
      texts[#texts + 1] = op.levels.done.reward
    end
    for _, text in pairs(texts) do
      if has_control(text) then
        return refuse("invalid_argument", "levels contain a control character")
      end
    end
  end
  local r, err, info = require("tasks_nvim.paths").set_levels(op.id, op.levels, {
    root = ctx.root,
    today = ctx.today,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    if info and (info.code == "invalid_argument" or info.code == "not_found") then
      return refuse(info.code, contract.redact(ctx.root, tostring(err)))
    end
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.changed and not ctx.dry and r.before then
    local list = {}
    for _, l in ipairs(r.before.list) do
      list[#list + 1] = json.object(l)
    end
    entry.inverse = json.object({
      op = "path_levels",
      id = r.id,
      levels = json.object({
        list = json.array(list),
        done = r.before.done and json.object(r.before.done) or nil,
      }),
      if_match = r.etag_after,
    })
  end
  return entry
end

---Promote a learning point (of a path or of a task's `## Lernpunkte`) to a task (`tasks_nvim.promote`).
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_promote(op, ctx)
  local ref = point_ref(op.point)
  if op.container == nil or ref == nil then
    return refuse("invalid_argument", "promote needs container and point")
  end
  for _, key in ipairs({ "container", "point", "area", "title", "actor" }) do
    if has_control(op[key]) then
      return refuse("invalid_argument", key .. " contains a control character")
    end
  end
  if op.title ~= nil and over_limit("title", op.title) then
    return refuse("payload_too_large", over_limit("title", op.title))
  end
  local r, err, info = require("tasks_nvim.promote").promote(op.container, ref, {
    root = ctx.root,
    today = ctx.today,
    area = op.area,
    title = op.title,
    actor = op.actor,
    if_match = op.if_match,
    dry_run = ctx.dry,
    index = false,
  })
  if not r then
    if info and (info.code == "invalid_argument" or info.code == "not_found") then
      return refuse(info.code, contract.redact(ctx.root, tostring(err)))
    end
    return mutate_failure(ctx, err, info)
  end
  local changed = {}
  if not ctx.dry then
    changed = { r.id, r.container }
    vim.list_extend(changed, r.repointed or {})
    ctx.touched[r.id:match("^([^/]+)/")] = true
    ctx.touched[r.container:match("^([^/]+)/")] = true
  end
  return {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_create" or "created",
    promoted_from = r.point,
    moved = r.moved,
    repointed = r.repointed,
    file = r.path and rel(ctx, r.path) or nil,
    changed_ids = changed,
    inverse = (not ctx.dry) and json.object({
      op = "unpromote",
      id = r.id,
      container = r.container,
      point = r.key,
    }) or nil,
  }
end

---Take a promotion back while the task holds no work of its own (`promote.unpromote`).
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_unpromote(op, ctx)
  local ref = point_ref(op.point)
  if op.container == nil or ref == nil then
    return refuse("invalid_argument", "unpromote needs container and point")
  end
  local r, err, info = require("tasks_nvim.promote").unpromote(op.container, ref, {
    root = ctx.root,
    today = ctx.today,
    if_match = op.if_match,
    dry_run = ctx.dry,
    index = false,
  })
  if not r then
    if info and (info.code == "invalid_argument" or info.code == "not_found") then
      return refuse(info.code, contract.redact(ctx.root, tostring(err)))
    end
    return mutate_failure(ctx, err, info)
  end
  local changed = {}
  if not ctx.dry then
    changed = { r.container, r.id }
    vim.list_extend(changed, r.repointed or {})
    ctx.touched[r.container:match("^([^/]+)/")] = true
    ctx.touched[r.id:match("^([^/]+)/")] = true
  end
  return {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_remove" or "removed",
    container = r.container,
    repointed = r.repointed,
    changed_ids = changed,
  }
end

---The answer of a view operation that failed: the engine's words and the code that says why.
---@param ctx Tasks.OpsCtx
---@param err string|nil
---@param info table|nil
---@return table
local function view_failure(ctx, err, info)
  if info and info.code == "invalid_argument" then
    return refuse("invalid_argument", tostring(err), info.details)
  end
  if info and info.code == "not_found" then
    return refuse("not_found", tostring(err))
  end
  return mutate_failure(ctx, err, info)
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_view_save(op, ctx)
  if op.view == nil then
    return refuse("invalid_argument", "view_save needs view")
  end
  local area, slug = op.area, op.slug
  if op.id ~= nil then
    if area ~= nil or slug ~= nil then
      return refuse("invalid_argument", "view_save takes id or area, not both")
    end
    area, slug = tostring(op.id):match("^([^/]+)/([^/]+)$")
    if not area then
      return refuse("invalid_argument", "expected <area>/<slug>")
    end
  elseif area == nil then
    return refuse("invalid_argument", "view_save needs id or area")
  end
  local views = require("tasks_nvim.views")
  local r, err, info = views.save(ctx.root, area, op.view, {
    slug = slug,
    if_match = op.if_match,
    today = ctx.today,
    dry_run = ctx.dry,
  })
  if not r then
    return view_failure(ctx, err, info)
  end
  local outcome = r.created and "created" or (r.changed and "changed" or "unchanged")
  local entry = {
    ok = true,
    id = r.id,
    outcome = ctx.dry and ("would_" .. (r.created and "create" or "change")) or outcome,
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = {},
  }
  if ctx.dry or not r.changed then
    return entry
  end
  if r.created then
    entry.inverse = json.object({ op = "view_delete", id = r.id, if_match = r.etag_after })
  elseif r.before then
    entry.inverse = json.object({
      op = "view_save",
      id = r.id,
      view = json.object(r.before),
      if_match = r.etag_after,
    })
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_view_delete(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "view_delete needs id")
  end
  if op.if_match == nil then
    return refuse(
      "invalid_argument",
      "view_delete needs if_match (the version of the view that was read)"
    )
  end
  local views = require("tasks_nvim.views")
  local r, err, info = views.delete(ctx.root, op.id, { if_match = op.if_match, dry_run = ctx.dry })
  if not r then
    return view_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_delete" or "deleted",
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    changed_ids = {},
  }
  if not ctx.dry and r.before then
    entry.inverse = json.object({ op = "view_save", id = r.id, view = json.object(r.before) })
  end
  return entry
end

---`attach` { id, from, name? }: the clipboard image or the newest screenshot becomes an asset of the task.
---The folders are those the caller named with `attach_dirs` (the hub, from its settings), else those of the
---configuration (`attach.screenshot_dirs`); an operation names no path of this machine.
---A dry run checks the request and the task and reads neither the clipboard nor a folder.
---The entry of `claim` and `release`: the task file changes (`doing` and back) and its version tag with it.
---@param ctx Tasks.OpsCtx
---@param id string
---@param before string|nil  # version tag before
---@param changed boolean
---@return table entry
local function claim_entry(ctx, id, before, changed)
  local task = scan.find(id, { root = ctx.root })
  local entry = {
    ok = true,
    id = id,
    outcome = changed and "changed" or "unchanged",
    etag_before = before,
    etag_after = task and task.etag or before,
    changed_ids = changed and { id } or {},
  }
  local area = vault.parse_id(id)
  if area then
    ctx.touched[area] = true
  end
  return entry
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_claim(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "claim needs id")
  end
  local task = scan.find(op.id, { root = ctx.root })
  if not task then
    return refuse("not_found", "no such open task: " .. tostring(op.id))
  end
  local opts = {
    root = ctx.root,
    today = ctx.today,
    by = op.by,
    for_ = op["for"],
    renew = op.renew,
    force = op.force,
    note = op.note,
  }
  if ctx.dry then
    local ok, gerr, ginfo = claims.guard(ctx.root, op.id, opts)
    if not ok then
      return mutate_failure(ctx, gerr, ginfo)
    end
    return {
      ok = true,
      id = op.id,
      outcome = "would_change",
      etag_before = task.etag,
      changed_ids = {},
    }
  end
  local r, err, info = claims.acquire(op.id, opts)
  if not r then
    return mutate_failure(ctx, err, info)
  end
  return claim_entry(ctx, op.id, task.etag, true)
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_release(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "release needs id")
  end
  local task = scan.find(op.id, { root = ctx.root })
  local opts = {
    root = ctx.root,
    today = ctx.today,
    by = op.by,
    force = op.force,
    note = op.note,
    status = op.status,
  }
  if ctx.dry then
    local ok, gerr, ginfo = claims.guard(ctx.root, op.id, opts)
    if not ok then
      return mutate_failure(ctx, gerr, ginfo)
    end
    return {
      ok = true,
      id = op.id,
      outcome = "would_change",
      etag_before = task and task.etag,
      changed_ids = {},
    }
  end
  local r, err, info = claims.release(op.id, opts)
  if not r then
    return mutate_failure(ctx, err, info)
  end
  return claim_entry(ctx, op.id, task and task.etag, r.released or r.status ~= nil)
end

---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_attach(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "attach needs id")
  end
  if op.from ~= "clipboard" and op.from ~= "latest" and op.from ~= "upload" then
    return refuse("invalid_argument", "attach needs from: 'clipboard', 'latest' or 'upload'")
  end
  -- A file the caller of the engine put into its folder; no other way there. The answer names no path.
  if op.from == "upload" then
    if not (ctx.attach and ctx.attach.upload_dir) then
      return refuse("invalid_argument", "attach: no upload folder was given")
    end
    if not require("tasks_nvim.attach_source").plain_upload_name(op.upload) then
      return refuse("invalid_argument", "attach: upload must be a plain file name")
    end
    if type(op.name) ~= "string" or op.name == "" then
      return refuse("invalid_argument", "attach: an upload needs a name")
    end
  elseif op.upload ~= nil then
    return refuse("invalid_argument", "attach: upload belongs to from: 'upload'")
  elseif op.exact ~= nil then
    return refuse("invalid_argument", "attach: exact belongs to from: 'upload'")
  end
  -- The folder of the asset below `assets/`: the one of its kind. The clipboard and the screenshot folders hold
  -- screenshots (the kind they get without one named); an upload without a kind lies in `assets/` itself.
  local kind = op.kind
  if kind == nil and op.from ~= "upload" then
    kind = "screenshot"
  end
  local asset_dir = mutate.asset_dir(kind)
  if not asset_dir then
    return refuse("invalid_argument", "attach: kind must be " .. mutate.ASSET_KINDS_TEXT)
  end
  -- The caller named the folders, and none: only the clipboard (the folders of the system are not looked into).
  if
    op.from == "latest"
    and ctx.attach
    and ctx.attach.dirs_given
    and #(ctx.attach.dirs or {}) == 0
  then
    return refuse(
      "invalid_argument",
      "attach: no screenshot folders were given, only the clipboard is read"
    )
  end
  local drafts = drafts_of(ctx)
  -- an occurrence of a series gets its file before anything is attached (a dry run: the file it would get)
  local task, ferr
  if ctx.dry then
    task = require("tasks_nvim.meeting_write").occurrence_target(op.id, ctx.root)
  elseif is_meeting(ctx, op.id) then
    local made, merr, minfo =
      require("tasks_nvim.meeting_write").materialize(op.id, { root = ctx.root, today = ctx.today })
    if made == nil then
      return mutate_failure(ctx, merr, minfo)
    end
  end
  -- an open task, else an open plan or project file
  if not task then
    task, ferr = mutate.attach_target(op.id, ctx.root, drafts)
  end
  if not task then
    return mutate_failure(ctx, ferr)
  end
  -- `exact`: an asset of this name is there already (the same file, sent again): nothing is attached twice.
  local taken = "attach: the task has an asset of this name already"
  if op.exact and task.folder then
    local name = mutate.asset_name(op.name)
    if name and fsio.is_file(fsio.dirname(task.path) .. "/" .. asset_dir .. "/" .. name) then
      return refuse("exists", taken)
    end
  end
  local entry = {
    ok = true,
    id = task.id,
    outcome = ctx.dry and "would_change" or "changed",
    -- A task an earlier `new` of a dry run would create has no file yet: its version is the one of the draft text.
    etag_before = (drafts and drafts[task.id]) and task.etag or etag_of_file(task.path),
    changed_ids = {},
  }
  if ctx.dry then
    return entry
  end
  local r, err = require("tasks_nvim.attach_source").attach(
    task.id,
    op.from,
    vim.tbl_extend(
      "force",
      { root = ctx.root, today = ctx.today, index = false },
      ctx.attach or {},
      {
        name = op.name,
        kind = kind,
        upload = op.upload,
        exact = op.exact == true or nil,
      }
    )
  )
  if not r then
    -- For folders the caller named (a page's request through the hub) the answer names no folder and no file of this
    -- machine: the page did not name them, and the person's user name is in their paths.
    if op.from == "latest" and ctx.attach and ctx.attach.dirs_given then
      return refuse("invalid_argument", "attach: no new image in the screenshot folders of the hub")
    end
    if op.from == "upload" and tostring(err):find("the upload is not there", 1, true) then
      return refuse("invalid_argument", "attach: the upload is not there")
    end
    -- Taken between the look above and the copy (the message of `mutate.attach` names a path: not passed on).
    if op.exact and tostring(err):find("^asset exists:") then
      return refuse("exists", taken)
    end
    return mutate_failure(ctx, err)
  end
  entry.etag_after = etag_of_file(r.path)
  entry.changed_ids = { r.id }
  entry.file = rel(ctx, r.path)
  entry.asset = r.rel
  entry.link = r.link
  if r.updated_err then
    entry.notes = { "updated was not set: " .. contract.redact(ctx.root, r.updated_err) }
  end
  ctx.touched[task.area] = true
  return entry
end

---`history_record` {}: write down the figures of today in the series of the vault (`tasks_nvim.history`): a row for
---every area whose figures changed since its last row; the folder is made on the first run. `rows` says how many
---(a dry run: how many it would be), `file` the month file. No task changes, so no `id` and no `inverse`.
---@param _ table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_history_record(_, ctx)
  local view, verr = contract.view({ root = ctx.root })
  if not view then
    return fail(ctx, verr)
  end
  local r, err = history.record(view, { today = ctx.today, dry_run = ctx.dry })
  if not r then
    return fail(ctx, err)
  end
  local outcome = "unchanged"
  if r.rows > 0 then
    outcome = ctx.dry and "would_change" or "changed"
  end
  return { ok = true, outcome = outcome, changed_ids = {}, rows = r.rows, file = r.file }
end

-- ── meetings ─────────────────────────────────────────────────────────────────

---The answer of a meeting operation that failed: a conflict keeps what the caller needs to try again (the version on
---disk, a free name for a board).
---@param ctx Tasks.OpsCtx
---@param err any
---@param info table|nil
---@return table
local function meeting_failure(ctx, err, info)
  if info and info.code == "conflict" then
    return refuse("conflict", contract.redact(ctx.root, tostring(err)), {
      actual = info.actual,
      expected = info.expected,
      suggestion = info.suggestion,
    })
  end
  if info and info.code then
    return refuse(info.code, contract.redact(ctx.root, tostring(err)), info.details)
  end
  return mutate_failure(ctx, err, info)
end

---The entry of a meeting edit (`meeting_write.edit`): changed or not, the versions, the meeting's area touched.
---@param ctx Tasks.OpsCtx
---@param r Tasks.MeetingEdit
---@return table
local function meeting_entry(ctx, r)
  return {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
    -- the first entry into an occurrence of a series made (would make) its file
    created = r.created or nil,
  }
end

---Whether any value of a table (deep) has a control character.
---@param t any
---@return boolean
local function any_control(t)
  if type(t) ~= "table" then
    return has_control(t)
  end
  for k, v in pairs(t) do
    if has_control(k) or any_control(v) then
      return true
    end
  end
  return false
end

---`meeting_new` { area, title, fields?, body?, slug?, lang? }: make a meeting file (`meeting_write.new`); a dry run names
---the id it would get.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_meeting_new(op, ctx)
  if op.area == nil or op.title == nil then
    return refuse("invalid_argument", "meeting_new needs area and title")
  end
  if
    any_control(op.fields)
    or has_control(op.title)
    or has_control(op.slug)
    or has_control(op.body)
  then
    return refuse("invalid_argument", "the meeting contains a control character")
  end
  if op.body and too_long(op.body, M.MAX_BODY) then
    return refuse("payload_too_large", ("body is longer than %d characters"):format(M.MAX_BODY))
  end
  local over = over_limit("title", op.title)
  for key, value in pairs(op.fields or {}) do
    over = over or over_limit(key, value)
  end
  if over then
    return refuse("payload_too_large", over)
  end
  if op.lang ~= nil and op.lang ~= "de" and op.lang ~= "en" then
    return refuse("invalid_argument", "lang must be de or en")
  end
  local r, err, info = require("tasks_nvim.meeting_write").new(op.area, {
    root = ctx.root,
    today = ctx.today,
    title = op.title,
    fields = op.fields,
    body = op.body,
    slug = op.slug,
    lang = op.lang,
    dry_run = ctx.dry,
  })
  if not r then
    return meeting_failure(ctx, err, info)
  end
  return {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_create" or "created",
    file = rel(ctx, r.path),
    slug = r.slug,
    renamed = r.renamed,
    etag_after = (not ctx.dry) and etag_of_file(r.path) or nil,
    changed_ids = ctx.dry and {} or { r.id },
  }
end

---`meeting_set` { id, patch, if_match? }: change the frontmatter of a meeting; the answer has an `inverse`.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_meeting_set(op, ctx)
  if op.id == nil or op.patch == nil then
    return refuse("invalid_argument", "meeting_set needs id and patch")
  end
  if any_control(op.patch) then
    return refuse("invalid_argument", "the patch contains a control character")
  end
  for key, value in pairs(op.patch) do
    local over = over_limit(key, value)
    if over then
      return refuse("payload_too_large", over)
    end
  end
  local r, err, info = require("tasks_nvim.meeting_write").set(op.id, op.patch, {
    root = ctx.root,
    today = ctx.today,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    return meeting_failure(ctx, err, info)
  end
  local entry = meeting_entry(ctx, r)
  if r.changed and not ctx.dry then
    entry.inverse = json.object({
      op = "meeting_set",
      id = r.id,
      patch = json.object(r.before),
      if_match = r.etag_after,
    })
  end
  return entry
end

---`meeting_close` { id, result?, if_match? }: finish a meeting at any time; `result` writes `## Ergebnis` in the same
---step; `without_result` says it has none. The inverse opens it again (`meeting_set` status planned).
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_meeting_close(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "meeting_close needs id")
  end
  if op.result ~= nil and (has_control(op.result) or too_long(op.result, M.MAX_SECTION)) then
    return refuse("invalid_argument", "result is too long or contains a control character")
  end
  local r, err, info = require("tasks_nvim.meeting_write").close(op.id, {
    root = ctx.root,
    today = ctx.today,
    if_match = op.if_match,
    dry_run = ctx.dry,
    result = op.result,
  })
  if not r then
    return meeting_failure(ctx, err, info)
  end
  local entry = meeting_entry(ctx, r)
  entry.without_result = r.without_result
  if
    r.changed
    and not ctx.dry
    and r.status_before
    and r.status_before ~= "done"
    and op.result == nil
  then
    entry.inverse = json.object({
      op = "meeting_set",
      id = r.id,
      patch = json.object({ status = r.status_before }),
      if_match = r.etag_after,
    })
  end
  return entry
end

---`meeting_capture` { id, entry, if_match? }: one line of the minutes (`meeting_write.capture`); the inverse sets the
---body as it was (`set_body`).
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_meeting_capture(op, ctx)
  if op.id == nil or op.entry == nil then
    return refuse("invalid_argument", "meeting_capture needs id and entry")
  end
  local allowed = { kind = true, text = true, asset = true, at = true }
  for key, value in pairs(op.entry) do
    if not allowed[key] then
      return refuse(
        "invalid_argument",
        "entry: unknown field " .. tostring(key) .. " (kind, text, asset, at)"
      )
    end
    if type(value) ~= "string" then
      return refuse("invalid_argument", "entry." .. tostring(key) .. " must be text")
    end
  end
  if any_control(op.entry) then
    return refuse("invalid_argument", "entry contains a control character")
  end
  local r, err, info = require("tasks_nvim.meeting_write").capture(op.id, op.entry, {
    root = ctx.root,
    today = ctx.today,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    return meeting_failure(ctx, err, info)
  end
  local entry = meeting_entry(ctx, r)
  if r.changed and not ctx.dry and not too_long(r.body_before, M.MAX_SET_BODY) then
    entry.inverse =
      json.object({ op = "set_body", id = r.id, body = r.body_before, if_match = r.etag_after })
  end
  return entry
end

---`meeting_attend` { id, n | name, present?, if_match? }: tick (present, the default) or untick a participant.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_meeting_attend(op, ctx)
  if op.id == nil or (op.n == nil) == (op.name == nil) then
    return refuse("invalid_argument", "meeting_attend needs id and one of n and name")
  end
  if has_control(op.name) then
    return refuse("invalid_argument", "name contains a control character")
  end
  local present = op.present ~= false
  local r, err, info = require("tasks_nvim.meeting_write").attend(
    op.id,
    { n = op.n, name = op.name },
    present,
    {
      root = ctx.root,
      today = ctx.today,
      if_match = op.if_match,
      dry_run = ctx.dry,
    }
  )
  if not r then
    return meeting_failure(ctx, err, info)
  end
  local entry = meeting_entry(ctx, r)
  if r.changed and not ctx.dry then
    entry.inverse = json.object({
      op = "meeting_attend",
      id = r.id,
      n = op.n,
      name = op.name,
      present = r.was_present == true,
      if_match = r.etag_after,
    })
  end
  return entry
end

---`meeting_followups` { id, n?, area?, fields? }: make tasks of the follow-ups (line `n`, else every line without a
---task), each with `refs: [<meeting>]`; `items` tells each line (`ok`, `id` or `error`). No `inverse`.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_meeting_followups(op, ctx)
  if op.id == nil then
    return refuse("invalid_argument", "meeting_followups needs id")
  end
  if any_control(op.fields) or has_control(op.area) then
    return refuse("invalid_argument", "the request contains a control character")
  end
  local r, err, info = require("tasks_nvim.meeting_write").followups(op.id, {
    root = ctx.root,
    today = ctx.today,
    items = op.n and { op.n } or nil,
    area = op.area,
    fields = op.fields,
    dry_run = ctx.dry,
  })
  if not r then
    return meeting_failure(ctx, err, info)
  end
  local items, made = {}, {}
  for _, item in ipairs(r.items) do
    items[#items + 1] = json.object({
      n = item.n,
      ok = item.ok,
      id = item.id,
      error = item.error and contract.redact(ctx.root, item.error) or nil,
      note = item.note and contract.redact(ctx.root, item.note) or nil,
    })
    if item.ok and item.id and item.code ~= "unchanged" and not ctx.dry then
      made[#made + 1] = item.id
    end
  end
  if #made > 0 then
    ctx.touched[r.area] = true
  end
  local changed = vim.list_extend({}, made)
  if r.changed and not ctx.dry then
    table.insert(changed, 1, r.id)
  end
  return {
    ok = true,
    id = r.id,
    outcome = (#made > 0 or r.changed) and (ctx.dry and "would_change" or "changed")
      or (ctx.dry and #r.items > 0 and "would_change" or "unchanged"),
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    items = items,
    notes = r.error and { contract.redact(ctx.root, tostring(r.error)) } or nil,
    changed_ids = changed,
  }
end

---`board_save` { id, name, format, upload, preview?, if_match? }: save a whiteboard into `assets/boards/` of a meeting,
---task, plan or project; a board that is there is replaced only on the version read. The answer has `asset`,
---`preview`, `etag` and `created`.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_board_save(op, ctx)
  if op.id == nil or op.name == nil or op.format == nil or op.upload == nil then
    return refuse("invalid_argument", "board_save needs id, name, format and upload")
  end
  if not (ctx.attach and ctx.attach.upload_dir) then
    return refuse("invalid_argument", "board_save: no upload folder was given")
  end
  if has_control(op.name) then
    return refuse("invalid_argument", "name contains a control character")
  end
  local r, err, info = require("tasks_nvim.meeting_write").board_save(op.id, {
    root = ctx.root,
    today = ctx.today,
    name = op.name,
    format = op.format,
    upload = op.upload,
    preview = op.preview,
    if_match = op.if_match,
    upload_dir = ctx.attach.upload_dir,
    dry_run = ctx.dry,
  })
  if not r then
    return meeting_failure(ctx, err, info)
  end
  local area = r.id:match("^([^/]+)/")
  if not ctx.dry then
    ctx.touched[area] = true
  end
  return {
    ok = true,
    id = r.id,
    outcome = ctx.dry and (r.created and "would_create" or "would_change")
      or (r.created and "created" or "changed"),
    file = rel(ctx, r.path),
    asset = r.asset,
    preview = r.preview,
    etag = r.etag,
    created = r.created,
    changed_ids = ctx.dry and {} or { r.id },
  }
end

-- ── milestones ───────────────────────────────────────────────────────────────

---`milestone_new`: make a milestone file.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_milestone_new(op, ctx)
  if op.area == nil or op.title == nil then
    return refuse("invalid_argument", "milestone_new needs area and title")
  end
  for _, key in ipairs({ "area", "title", "due", "close", "status", "summary", "slug", "includes" }) do
    if has_control(op[key]) then
      return refuse("invalid_argument", key .. " contains a control character")
    end
  end
  local over = over_limit("title", op.title)
    or over_limit("area", op.area)
    or (op.slug and over_limit("slug", op.slug))
    or (op.summary and over_limit("summary", op.summary))
    or (op.includes and over_limit("includes", op.includes))
  if over then
    return refuse("payload_too_large", over)
  end
  local r, err, info = require("tasks_nvim.milestones").new(op.area, {
    root = ctx.root,
    today = ctx.today,
    title = op.title,
    due = op.due,
    includes = op.includes,
    close = op.close,
    status = op.status,
    summary = op.summary,
    slug = op.slug,
    dry_run = ctx.dry,
  })
  if not r then
    if info and info.code == "invalid_argument" then
      return refuse("invalid_argument", tostring(err), info.details)
    end
    return mutate_failure(ctx, err, info)
  end
  return {
    ok = true,
    id = r.id,
    outcome = ctx.dry and "would_create" or "created",
    file = rel(ctx, r.path),
    slug = r.slug,
    renamed = r.renamed,
    changed_ids = ctx.dry and {} or { r.id },
  }
end

---`milestone_set`: change the frontmatter of a milestone; the answer has an `inverse`.
---@param op table
---@param ctx Tasks.OpsCtx
---@return table entry
local function do_milestone_set(op, ctx)
  if op.id == nil or op.patch == nil then
    return refuse("invalid_argument", "milestone_set needs id and patch")
  end
  for key, value in pairs(op.patch) do
    if has_control(key) or has_control(value) then
      return refuse("invalid_argument", "the patch contains a control character")
    end
    local over = over_limit(key, value)
    if over then
      return refuse("payload_too_large", over)
    end
  end
  local r, err, info = require("tasks_nvim.milestones").set(op.id, op.patch, {
    root = ctx.root,
    today = ctx.today,
    if_match = op.if_match,
    dry_run = ctx.dry,
  })
  if not r then
    if info and info.code == "invalid_argument" then
      return refuse("invalid_argument", tostring(err), info.details)
    end
    if info and info.code == "not_found" then
      return refuse("not_found", tostring(err))
    end
    return mutate_failure(ctx, err, info)
  end
  local entry = {
    ok = true,
    id = r.id,
    outcome = r.changed and (ctx.dry and "would_change" or "changed") or "unchanged",
    file = rel(ctx, r.path),
    etag_before = r.etag_before,
    etag_after = (not ctx.dry) and r.etag_after or nil,
    changed_ids = (r.changed and not ctx.dry) and { r.id } or {},
  }
  if r.changed and not ctx.dry then
    entry.inverse = json.object({
      op = "milestone_set",
      id = r.id,
      patch = json.object(r.before),
      if_match = r.etag_after,
    })
  end
  return entry
end

---Bring the milestones in line after an operation of `SETTLES` that wrote something: what it reached or opened again
---goes into its entry (and into `changed_ids`). A failure is a note; the operation stands.
---@param name string
---@param entry table
---@param ctx Tasks.OpsCtx
---@return table entry
local function settle_after(name, entry, ctx)
  if ctx.dry or not SETTLES[name] or type(entry) ~= "table" or not entry.ok then
    return entry
  end
  if #(entry.changed_ids or {}) == 0 then
    return entry
  end
  local ran, res =
    pcall(require("tasks_nvim.milestones").settle, { root = ctx.root, today = ctx.today })
  if not ran then
    entry.notes = entry.notes or {}
    entry.notes[#entry.notes + 1] =
      contract.redact(ctx.root, "reaching milestones: " .. tostring(res))
    return entry
  end
  if #res.reached > 0 then
    entry.milestones_reached = res.reached
  end
  if #res.reopened > 0 then
    entry.milestones_reopened = res.reopened
  end
  for _, id in ipairs(vim.list_extend(vim.list_slice(res.reached, 1), res.reopened)) do
    if not vim.tbl_contains(entry.changed_ids, id) then
      entry.changed_ids[#entry.changed_ids + 1] = id
    end
  end
  for _, note in ipairs(res.notes) do
    entry.notes = entry.notes or {}
    entry.notes[#entry.notes + 1] = contract.redact(ctx.root, note)
  end
  return entry
end

---@type table<string, fun(op: table, ctx: Tasks.OpsCtx): table>
local HANDLERS = {
  milestone_new = do_milestone_new,
  milestone_set = do_milestone_set,
  meeting_new = do_meeting_new,
  meeting_set = do_meeting_set,
  meeting_close = do_meeting_close,
  meeting_capture = do_meeting_capture,
  meeting_attend = do_meeting_attend,
  meeting_followups = do_meeting_followups,
  board_save = do_board_save,
  set = do_set,
  new = do_new,
  reorder = do_reorder,
  done = do_done,
  move_area = do_move_area,
  plan_new = do_plan_new,
  plan_set = do_plan_set,
  path_new = do_path_new,
  path_set = do_path_set,
  path_close = do_path_close,
  node_set = do_node_set,
  path_reward = do_path_reward,
  path_levels = do_path_levels,
  promote = do_promote,
  unpromote = do_unpromote,
  plan_close = do_plan_close,
  project_new = do_project_new,
  project_set = do_project_set,
  project_close = do_project_close,
  tick_step = do_tick_step,
  add_steps = do_add_steps,
  answer = do_answer,
  append_note = do_append_note,
  reopen = do_reopen,
  set_body = do_set_body,
  set_section = do_set_section,
  view_save = do_view_save,
  view_delete = do_view_delete,
  attach = do_attach,
  claim = do_claim,
  release = do_release,
  history_record = do_history_record,
}

-- ── the request ──────────────────────────────────────────────────────────────

---The door: shape check, the loop over the operations, the `tasks.result` document and the entries a document
---cannot hold are `lib.nvim.contract.ops`'s; what an operation DOES is a handler above.
local ops = {}
for _, name in ipairs(M.OPS) do
  local handler = HANDLERS[name]
  -- the acting name of the operation is what `claims.guard` judges the write by
  ops[name] = {
    fields = FIELDS[name],
    run = function(op, ctx)
      -- While git rewrites the tree (a pull with an autostash of another session) a file holds HEAD's text and the
      -- change this write makes is lost or collides when the autostash comes back: wait for git, or write nothing.
      -- One place for every operation; a dry run writes nothing and does not wait. `done` waits again itself (it
      -- also looks after the finish), which costs one look at the git directory.
      if not ctx.dry then
        local what, where =
          gitbusy.wait(ctx.root, ctx.git_wait_ms and { git_wait_ms = ctx.git_wait_ms } or nil)
        if what then
          ---@cast where string
          return fail(ctx, gitbusy.message(what, where), { code = "locked", retryable = true })
        end
      end
      return settle_after(
        name,
        claims.with_identity({ by = op.by, force = op.force, note = op.note }, handler, op, ctx),
        ctx
      )
    end,
  }
end

door = contract_ops.make({
  doc = contract.doc,
  order = M.OPS,
  ops = ops,
  limits = { batch_ops = contract.LIMITS.batch_ops, client_op_id = M.MAX_CLIENT_OP_ID },
  patterns = contract.ERROR_PATTERNS,
  ---@param params table
  ---@param opts { root?: string, today?: string, attach?: Tasks.AttachSourceOpts }
  ---@return Tasks.OpsCtx|nil ctx
  ---@return Tasks.ContractError|string|nil err
  context = function(params, opts)
    local root, rerr = vault.root(opts)
    if not root then
      return nil, rerr
    end
    local today = opts.today or model.today()
    if not model.is_date(today) then
      return nil, errors.fail("invalid_argument", "today is not a date (YYYY-MM-DD)")
    end
    return {
      root = root,
      today = today,
      dry = params.dry_run == true,
      touched = {},
      claimed = {},
      created = {},
      drafts = {},
      files = {},
      attach = opts.attach,
      git_wait_ms = opts.git_wait_ms,
    }
  end,
  ---The index of every area that changed, once.
  ---@param ctx Tasks.OpsCtx
  ---@param results table[]
  finish = function(ctx, results)
    if ctx.dry then
      return
    end
    local areas = vim.tbl_keys(ctx.touched)
    table.sort(areas)
    local by_area = {}
    for _, area in ipairs(areas) do
      -- a raise is told like any other failure of the write: the hook of the door must not raise (the door would put a
      -- `finish_error` into the document, a field tasks-ops/1 does not have)
      local called, res, ierr = pcall(index.write_area, area, { root = ctx.root })
      if not called then
        res, ierr = nil, res
      end
      by_area[area] = res and { action = res.action }
        or { action = "error", error = contract.redact(ctx.root, tostring(ierr)) }
    end
    for _, entry in ipairs(results) do
      local area = entry.id and entry.id:match("^([^/]+)/")
      if entry.ok and by_area[area] and #entry.changed_ids > 0 then
        entry.index = json.object(by_area[area])
      end
    end
  end,
})

---Run a request and answer it with a `tasks.result` document.
---@param params { client_op_id?: string, dry_run?: boolean, ops?: table[] }  # The request without its `schema`.
---@param opts? { root?: string, today?: string, attach?: Tasks.AttachSourceOpts }
---@return table|nil doc
---@return Lib.Contract.Error|Tasks.ContractError|string|nil err
function M.run(params, opts)
  return door.run(params, opts)
end

return M
