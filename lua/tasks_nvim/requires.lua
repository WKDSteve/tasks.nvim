---@module 'tasks_nvim.requires'
---@brief Learning paths and projects that build on each other: `requires: [id, ...]` and `requires_gate: soft|hard`.
---@description
--- A learning path or a project names the paths and projects it builds on (`requires:`, ids or wikilinks). A
--- requirement is met once that path or project is finished (closed into a Backlog). The gate says what an unmet one
--- does: `soft` (the default) only says so (`waiting_on`, a note when the item is finished anyway); `hard` keeps the item
--- from being finished (`paths.close`, `done_flow.close_projects`) and the line of the whole path in `## Level` open.
--- Work on the item may start at any time: the gate is about finishing it, never about beginning it.
---
--- A plan has no `requires:` (its order is its stages and the `blocked_by` of its tasks).
---
--- This module reads the two fields (`read`, called by `plans.parse`), knows every path and project of the vault and
--- whether it is finished (`index`), tells what one waits for (`state`) and finds the circles (`cycles`).
---
--- Not its job: the documents, the views, `check`'s findings (`tasks_nvim.check`).

local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---The words of `requires_gate`; the first is the default.
---@type string[]
M.GATES = { "soft", "hard" }

---The longest text an entry of `requires` that is no id of this vault keeps (`foreign`, `bad`).
M.ENTRY_MAX = 200

---Whether an entry of `requires` names an id of another vault: `<vault>:<area>/<slug>` or `<vault>/<area>/<slug>`
---(the forms a milestone's `includes` calls foreign, `milestones.member`).
---@param value string
---@return boolean
function M.is_foreign(value)
  local _, slashes = value:gsub("/", "")
  return value:find(":", 1, true) ~= nil or slashes >= 2
end

---Read `requires` and `requires_gate` of a path or project file into `plan` (`requires`, `requires_raw`,
---`requires_entries`, `requires_gate`, `link_problems`). `requires_entries` is the list in the file's order with the
---entries no requirement can be made of kept as `{ id = <as written>, kind = "foreign"|"bad" }` (the documents show
---them; the file's fault stays `plan-bad-requires`); a resolved one is `{ id = <id> }`. A plan file must have neither (`plan-requires`). `bad` takes the codes with the
---`plan-` prefix (`plans.parse` turns them into `path-...` / `project-...`).
---@param meta table
---@param plan Tasks.PlanFile
---@param bad fun(code: string, msg: string)
---@param resolver? Tasks.LinkResolver
function M.read(meta, plan, bad, resolver)
  local model = require("tasks_nvim.model")
  local fsio = require("tasks_nvim.fsio")
  if plan.kind == "plan" then
    if meta.requires ~= nil or meta.requires_gate ~= nil then
      bad(
        "plan-requires",
        "a plan has no requires or requires_gate: its order is its stages and the blocked_by of its tasks"
      )
    end
    return
  end
  local list = model.field_list(meta.requires, "requires", bad)
  plan.requires, plan.requires_raw, plan.requires_entries = {}, {}, {}
  local seen = {}
  ---An entry no requirement can be made of, kept for the documents: once, as written (one line, clipped).
  local function keep(odd, text)
    text = vim.trim(fsio.clean(text)):sub(1, M.ENTRY_MAX)
    if text ~= "" and not seen[text] then
      seen[text] = true
      plan.requires_entries[#plan.requires_entries + 1] = { id = text, kind = odd }
    end
  end
  for _, raw in ipairs(list) do
    raw = vim.trim(raw)
    local kind, value = wikilinks.read(raw)
    local id
    if kind == "bad" then
      bad("plan-bad-requires", "requires: " .. value)
      keep("bad", raw)
    elseif kind == "slug" then
      local ids = resolver and resolver.candidates(value) or {}
      if #ids == 1 then
        id = ids[1]
      else
        plan.link_problems = plan.link_problems or {}
        table.insert(plan.link_problems, {
          code = #ids == 0 and "wikilink-dangling" or "wikilink-ambiguous",
          field = "requires",
          raw = raw,
          candidates = vim.list_slice(ids, 1),
        })
      end
    else
      local _, slug, err = vault.parse_id(value)
      if err or not slug then
        bad(
          "plan-bad-requires",
          "requires: " .. (err or ("expected <area>/<slug>, got " .. fsio.clean(value)))
        )
        if M.is_foreign(value) then
          keep("foreign", value)
        else
          keep("bad", raw)
        end
      else
        id = value
      end
    end
    if id then
      if seen[id] then
        bad("plan-bad-requires", "requires names " .. id .. " twice")
      else
        seen[id] = true
        plan.requires[#plan.requires + 1] = id
        plan.requires_raw[#plan.requires_raw + 1] = raw
        plan.requires_entries[#plan.requires_entries + 1] = { id = id }
      end
    end
  end
  local gate = model.field_text(meta.requires_gate, "requires_gate", bad)
  if gate then
    gate = vim.trim(gate)
    if vim.tbl_contains(M.GATES, gate) then
      plan.requires_gate = gate
    else
      bad(
        "plan-bad-requires-gate",
        "requires_gate must be soft or hard, got '" .. fsio.clean(gate) .. "'"
      )
    end
  end
end

---The ids a value of `requires` names, as a write takes it: a list or a text split at commas, each an id or a wikilink
---(resolved to its id: the file is written with ids). Each once.
---@param value string[]|string
---@param resolver? Tasks.LinkResolver
---@return string[]|nil ids
---@return string|nil err
function M.ids_of(value, resolver)
  local items = value
  if type(value) ~= "table" then
    -- `a/b,c/d` or the flow list `[a/b, c/d]` of the shell (`tasks set <id> "requires=[a/b,c/d]"`)
    local text = vim.trim(tostring(value))
    if text:sub(1, 1) == "[" and text:sub(-1) == "]" and text:sub(1, 2) ~= "[[" then
      text = text:sub(2, -2)
    end
    items = vim.split(text, ",", { plain = true })
  end
  local out, seen = {}, {}
  for _, item in ipairs(items) do
    local text = vim.trim(tostring(item))
    if text ~= "" then
      if text:find("[\r\n]") then
        return nil, "requires: an entry must be one line"
      end
      local id, err = wikilinks.typed_id(text, "requires", resolver)
      if not id then
        return nil, err
      end
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  return out, nil
end

---A value of `requires_gate` as a write takes it.
---@param value any
---@return string|nil gate
---@return string|nil err
function M.gate_of(value)
  local text = type(value) == "string" and vim.trim(value) or nil
  if not text or not vim.tbl_contains(M.GATES, text) then
    return nil, "requires_gate must be soft or hard, got '" .. tostring(value) .. "'"
  end
  return text, nil
end

---@class Tasks.RequiresItem
---@field id string
---@field kind "path"|"project"
---@field title string
---@field done boolean
---@field file? Tasks.PlanFile  # The open file (absent for a finished one).

---@class Tasks.RequiresIndex
---@field items table<string, Tasks.RequiresItem>  # Every path and project of the vault, open and finished, by id.

---Every learning path and project of the vault, open (their files) and finished (the Backlog items with
---`closed_kind: path|project`). `opts.paths`, `opts.projects`, `opts.finished` take lists read already.
---@param opts { root?: string, paths?: Tasks.PlanFile[], projects?: Tasks.PlanFile[], finished?: Tasks.Task[] }
---@return Tasks.RequiresIndex
function M.index(opts)
  local projects_mod = require("tasks_nvim.projects")
  local items = {}
  local finished = opts.finished or projects_mod.finished_items({ root = opts.root })
  for _, item in ipairs(finished) do
    local kind = projects_mod.finished_kind(item)
    if kind == "path" or kind == "project" then
      items[item.id] = { id = item.id, kind = kind, title = item.title or item.id, done = true }
    end
  end
  local open_paths = opts.paths or require("tasks_nvim.paths").all({ root = opts.root }) or {}
  local open_projects = opts.projects or projects_mod.all({ root = opts.root }) or {}
  for kind, list in pairs({ path = open_paths, project = open_projects }) do
    for _, f in ipairs(list) do
      -- an open file wins over a finished one of the same id (`check` says `open-in-backlog` or the like)
      items[f.id] = { id = f.id, kind = kind, title = f.title or f.id, done = false, file = f }
    end
  end
  return { items = items }
end

---Add (or replace) an open file in an index: a file as a change would leave it, or one about to be made.
---@param idx Tasks.RequiresIndex
---@param file Tasks.PlanFile
---@return Tasks.RequiresIndex
function M.with_file(idx, file)
  local items = {}
  for id, it in pairs(idx.items) do
    items[id] = it
  end
  items[file.id] =
    { id = file.id, kind = file.kind, title = file.title or file.id, done = false, file = file }
  return { items = items }
end

---@class Tasks.RequiresState
---@field requires string[]          # The ids the file names, in its order.
---@field gate "soft"|"hard"         # The gate of the file's own requirements.
---@field requirements { id: string, kind: "path"|"project"|"unknown"|"foreign"|"bad", gate: "soft"|"hard", met: boolean, title?: string }[]
---@field waiting_on string[]        # The open HARD requirements, its own and those of its project (ids).
---@field waiting { id: string, via?: string }[]  # The same, `via` the project a requirement is inherited from.
---@field open_soft string[]         # Its own open requirements under the soft gate: a hint, never a wait.
---@field unknown string[]           # Ids that are no path or project of the vault (nor the file itself).
---@field held boolean               # It waits: it cannot be finished (and a path's line of the whole path stays open).

---What a path or project builds on and waits for. A requirement is met once that path or project is finished. Only
---the hard gate makes an open one a wait (`waiting_on`); under the soft gate it stays a hint (`open_soft`), the item
---keeps its stage. A path of a project inherits the project's open hard requirements (`via` the project): a
---`requires` of a project holds for each of its paths. `nil` when the file names nothing and inherits nothing.
---@param file Tasks.PlanFile
---@param idx Tasks.RequiresIndex
---@return Tasks.RequiresState|nil
function M.state(file, idx)
  local own = file.requires or {}
  -- the entries in the file's order: the resolved ids and those that are no id of this vault (`foreign`, `bad`)
  local entries = file.requires_entries
    or vim.tbl_map(function(id)
      return { id = id }
    end, own)
  local parent
  if file.kind == "path" and file.project then
    local it = idx.items[file.project]
    parent = it and not it.done and it.file or nil
    if parent and not (parent.requires and #parent.requires > 0) then
      parent = nil
    end
  end
  if #entries == 0 and not parent then
    return nil
  end
  local gate = file.requires_gate or M.GATES[1]
  local st = {
    requires = vim.list_slice(own, 1),
    gate = gate,
    requirements = {},
    waiting_on = {},
    waiting = {},
    open_soft = {},
    unknown = {},
  }
  local listed = {}
  for _, e in ipairs(entries) do
    local id = e.id
    local it = not e.kind and idx.items[id] or nil
    if e.kind then
      -- an id of another vault or a broken entry: a box of the map, never a wait (the file's fault says the rest)
      st.requirements[#st.requirements + 1] = { id = id, kind = e.kind, gate = gate, met = false }
    elseif not it or id == file.id then
      st.unknown[#st.unknown + 1] = id
      st.requirements[#st.requirements + 1] =
        { id = id, kind = "unknown", gate = gate, met = false }
    else
      st.requirements[#st.requirements + 1] =
        { id = id, kind = it.kind, gate = gate, met = it.done, title = it.title }
      if not it.done then
        if gate == "hard" then
          listed[id] = true
          st.waiting_on[#st.waiting_on + 1] = id
          st.waiting[#st.waiting + 1] = { id = id }
        else
          st.open_soft[#st.open_soft + 1] = id
        end
      end
    end
  end
  if parent and (parent.requires_gate or M.GATES[1]) == "hard" then
    for _, id in ipairs(parent.requires) do
      local it = idx.items[id]
      if it and not it.done and id ~= file.id and id ~= parent.id and not listed[id] then
        listed[id] = true
        st.waiting_on[#st.waiting_on + 1] = id
        st.waiting[#st.waiting + 1] = { id = id, via = parent.id }
      end
    end
  end
  st.held = #st.waiting_on > 0
  return st
end

---The stage of a learning path for a map of them: `done` (finished), `parked`, `waiting` (an open hard requirement,
---`state.held`), `doing` (`status: doing`, or a point learned or seen), else `idle`. The soft gate never makes it wait.
---@param f Tasks.PlanFile
---@param st? Tasks.RequiresState
---@param finished? boolean  # The file is a finished one (from a Backlog).
---@return "done"|"parked"|"waiting"|"doing"|"idle"
function M.stage(f, st, finished)
  if finished or f.status == "done" then
    return "done"
  elseif f.status == "parked" then
    return "parked"
  elseif st and st.held then
    return "waiting"
  end
  local p = f.tree and f.tree.progress
  if f.status == "doing" or (p and (p.learned + p.seen) > 0) then
    return "doing"
  end
  return "idle"
end

---What an open file waits on as edges of the graph: its own requirements, and for a path of a project the hard
---requirements of that project (inherited, `state`), never the path itself.
---@param idx Tasks.RequiresIndex
---@param it Tasks.RequiresItem
---@return string[]
local function edges_of(idx, it)
  local f = it.file
  if not f then
    return {}
  end
  local out = vim.list_slice(f.requires or {}, 1)
  local parent = f.kind == "path" and f.project and idx.items[f.project] or nil
  local pf = parent and not parent.done and parent.file or nil
  if pf and (pf.requires_gate or M.GATES[1]) == "hard" then
    for _, id in ipairs(pf.requires or {}) do
      if id ~= f.id then
        out[#out + 1] = id
      end
    end
  end
  return out
end

---The circles of `requires` among the open paths and projects (a finished one ends every chain), the hard requirements
---a path inherits from its project included: each once, starting at its smallest id, in id order. A file that names
---itself is a circle of one.
---@param idx Tasks.RequiresIndex
---@return string[][]
function M.cycles(idx)
  local ids = vim.tbl_keys(idx.items)
  table.sort(ids)
  local color, stack, out, seen = {}, {}, {}, {}
  local function visit(id)
    color[id] = 1
    stack[#stack + 1] = id
    local it = idx.items[id]
    for _, nxt in ipairs(edges_of(idx, it)) do
      local n = idx.items[nxt]
      if n and not n.done then
        if color[nxt] == 1 then
          -- the circle is the stack from nxt on
          local cyc, from = {}, nil
          for i = #stack, 1, -1 do
            if stack[i] == nxt then
              from = i
              break
            end
          end
          for i = from, #stack do
            cyc[#cyc + 1] = stack[i]
          end
          -- rotate to the smallest id, so each circle is named once
          local min = 1
          for i = 2, #cyc do
            if cyc[i] < cyc[min] then
              min = i
            end
          end
          local rot = {}
          for i = 0, #cyc - 1 do
            rot[#rot + 1] = cyc[(min - 1 + i) % #cyc + 1]
          end
          local key = table.concat(rot, " ")
          if not seen[key] then
            seen[key] = true
            out[#out + 1] = rot
          end
        elseif not color[nxt] then
          visit(nxt)
        end
      end
    end
    stack[#stack] = nil
    color[id] = 2
  end
  for _, id in ipairs(ids) do
    if not color[id] and not idx.items[id].done then
      visit(id)
    end
  end
  table.sort(out, function(a, b)
    return table.concat(a, " ") < table.concat(b, " ")
  end)
  return out
end

---The circle a file is part of, if any (`cycles` of the index).
---@param idx Tasks.RequiresIndex
---@param id string
---@return string[]|nil
function M.cycle_of(idx, id)
  for _, cyc in ipairs(M.cycles(idx)) do
    if vim.tbl_contains(cyc, id) then
      return cyc
    end
  end
  return nil
end

---A circle as text: `a -> b -> a`.
---@param cyc string[]
---@return string
function M.cycle_text(cyc)
  return table.concat(cyc, " -> ") .. " -> " .. cyc[1]
end

---The problems of a file's requirements as a change would leave them: an id that is no path or project of the vault
---(`requires-unknown`) and a circle the change makes or keeps through the file (`requires-cycle`; through the paths of a
---project that inherit its hard requirements too). Empty when there are none.
---@param file Tasks.PlanFile  # The file as it would read (`requires` resolved to ids).
---@param idx Tasks.RequiresIndex
---@return { code: string, key: string, target: string, message: string }[]
function M.problems(file, idx)
  local out = {}
  local with = M.with_file(idx, file)
  for _, id in ipairs(file.requires or {}) do
    if id ~= file.id and not with.items[id] then
      out[#out + 1] = {
        code = "requires-unknown",
        key = "requires",
        target = id,
        message = "requires " .. id .. ": no learning path or project of that id",
      }
    end
  end
  -- a circle the change makes: through the file, or (a project's hard gate) through the paths that inherit it
  local before = {}
  for _, c in ipairs(M.cycles(idx)) do
    before[table.concat(c, " ")] = true
  end
  local cyc
  for _, c in ipairs(M.cycles(with)) do
    if not before[table.concat(c, " ")] then
      cyc = c
      break
    end
  end
  cyc = cyc or M.cycle_of(with, file.id)
  if cyc then
    out[#out + 1] = {
      code = "requires-cycle",
      key = "requires",
      target = cyc[1],
      message = "requires closes a circle: " .. M.cycle_text(cyc),
    }
  end
  return out
end

---A level state as the gate leaves it: a held path (hard gate, still waiting) keeps the line of the whole path open
---(`reached.done`, `finished`, its reward). A copy; the state as it was when nothing holds it.
---@param st? Tasks.LevelState
---@param req? Tasks.RequiresState
---@return Tasks.LevelState|nil
function M.hold_levels(st, req)
  if not st or not (req and req.held) then
    return st
  end
  local out = vim.tbl_extend("force", {}, st)
  out.finished = false
  out.reached = vim.tbl_extend("force", {}, st.reached or {})
  if out.reached.done ~= nil then
    out.reached.done = false
  end
  out.open_rewards = vim.tbl_filter(function(r)
    return r.ref ~= "done"
  end, st.open_rewards or {})
  return out
end

---The short text of what an item waits for, for the views: `waits for a, b (via <project>)` for the open hard
---requirements, else `builds on a, b (not finished)` for the open soft ones (a hint); nil when nothing is open.
---@param req? Tasks.RequiresState
---@return string|nil
function M.waiting_text(req)
  if not req then
    return nil
  end
  if #req.waiting > 0 then
    local parts = {}
    for _, w in ipairs(req.waiting) do
      parts[#parts + 1] = w.via and (w.id .. " (via " .. w.via .. ")") or w.id
    end
    return "waits for " .. table.concat(parts, ", ")
  elseif #req.open_soft > 0 then
    return "builds on " .. table.concat(req.open_soft, ", ") .. " (not finished)"
  end
  return nil
end

---Whether a list of path or project files names any requirement: only then is an index of the vault worth reading.
---@param ... Tasks.PlanFile[]
---@return boolean
function M.any(...)
  for _, files in ipairs({ ... }) do
    for _, f in ipairs(files or {}) do
      if (f.requires and #f.requires > 0) or (f.requires_entries and #f.requires_entries > 0) then
        return true
      end
    end
  end
  return false
end

return M
