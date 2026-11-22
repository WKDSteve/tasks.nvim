---@module 'tasks_nvim.contract_learn'
---@brief The documents of the learning views over all paths (`tasks.learn_next`, …): one request instead of a
---`tasks.path` per path.
---@description
--- The rules are `tasks_nvim.learn`'s; this module reads the paths of a scope and builds the documents of the contract
--- (`tasks_nvim.contract`: head, seal, redaction). Read only.

-- @scans-data

local contract = require("tasks_nvim.contract")
local fsio = require("tasks_nvim.fsio")
local json = require("lib.nvim.json.canonical")
local learn = require("tasks_nvim.learn")
local lernbaum = require("tasks_nvim.lernbaum")
local vault = require("tasks_nvim.vault")

local M = {}

---@param msg string
---@return Tasks.ContractError
local function bad_argument(msg)
  return { code = "invalid_argument", message = msg, retryable = false }
end

---The open paths of a scope: the vault, or an area (an area group stands for its members), narrowed to the ids of
---`params.paths` when given (an id that names no open path is left out).
---@param root string
---@param params { area?: string, paths?: string[] }
---@return Tasks.PlanFile[]|nil files
---@return string[]|Tasks.ContractError incomplete_or_err
function M.scope(root, params)
  local names
  if params.area ~= nil then
    local scope = vault.area_scope(root, params.area)
    if not scope then
      return nil,
        {
          code = "not_found",
          message = "unknown area: " .. tostring(params.area),
          retryable = false,
        }
    end
    names = scope.areas
  else
    names = vim.tbl_map(function(a)
      return a.name
    end, vault.areas(root))
  end
  local wanted
  if params.paths ~= nil then
    wanted = {}
    for _, id in ipairs(params.paths) do
      wanted[id] = true
    end
  end
  local paths_mod = require("tasks_nvim.paths")
  local files, incomplete = {}, {}
  for _, name in ipairs(names) do
    local list, errs = paths_mod.area(name, { root = root })
    for _, e in ipairs(type(errs) == "table" and errs or {}) do
      incomplete[#incomplete + 1] = contract.redact(root, tostring(e))
    end
    for _, f in ipairs(list or {}) do
      if not wanted or wanted[f.id] then
        files[#files + 1] = f
      end
    end
  end
  return files, incomplete
end

---The lines a path gives a document's `rev`: its file and the XP of the tasks its promoted points name.
---@param f Tasks.PlanFile
---@param text? string
---@return string[]
function M.rev_lines(f, text)
  local out = { f.id .. "\t" .. (text and fsio.etag(text) or "") }
  for _, n in ipairs(f.tree and f.tree.nodes or {}) do
    if n.promoted and n.xp_from == "task" then
      out[#out + 1] = "xp:" .. n.promoted .. "\t" .. tostring(n.xp)
    end
  end
  return out
end

---A point as the learning documents carry it: where it stands (`index`, `key`), its label, its stage (the root it
---stands below), its link and what its marks say.
---@param node Tasks.LernNode
---@return table
local function point_entry(node)
  local stage = learn.stage_of(node)
  return {
    index = node.index,
    key = node.key,
    label = node.label,
    stage_index = stage.index,
    stage_label = stage.label,
    link = node.link,
    promoted = node.promoted,
    h_min = node.h_min,
    h_max = node.h_max,
    xp = node.xp,
    safety = node.safety_eff and true or nil,
    machine = node.machine_eff and vim.list_slice(node.machine_eff, 1) or nil,
  }
end

---@param v any
---@return boolean
local function is_count(v, max)
  return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= max
end

---`tasks.learn_next`: for every running learning path (stage `doing`, or `idle` with its project begun, i.e. the
---project's `status: doing`) the first `n` points that may be learned now (`learn.next_points`), on the machine when
---one is named. Paths with such a point only; `doing` before `idle`, then the most recently updated first, then by id.
---@param params? { area?: string, paths?: string[], machine?: string, n?: integer }
---@param opts? { root?: string }
---@return table|nil doc
---@return Tasks.ContractError|string|nil err
function M.next(params, opts)
  params = params or {}
  if params.n ~= nil and not is_count(params.n, learn.MAX_NEXT) then
    return nil, bad_argument(("n must be 1..%d"):format(learn.MAX_NEXT))
  end
  if params.machine ~= nil and not vim.tbl_contains(lernbaum.MACHINES, params.machine) then
    return nil, bad_argument("machine must be one of " .. table.concat(lernbaum.MACHINES, ", "))
  end
  return fsio.read_scope(function()
    local root, rerr = vault.root(opts)
    if not root then
      return nil, rerr
    end
    local files, incomplete = M.scope(root, params)
    if not files then
      return nil, incomplete
    end
    local projects_mod = require("tasks_nvim.projects")
    local req = require("tasks_nvim.requires")
    local project_files = projects_mod.all({ root = root }) or {}
    local begun = {}
    for _, p in ipairs(project_files) do
      begun[p.id] = p.status == "doing"
    end
    local idx = req.any(files, project_files)
        and req.index({
          root = root,
          paths = require("tasks_nvim.paths").all({ root = root }) or {},
          projects = project_files,
        })
      or nil
    local lines = {}
    local chosen = {}
    for _, f in ipairs(files) do
      local text = fsio.read(f.path)
      vim.list_extend(lines, M.rev_lines(f, text))
      local stage = req.stage(f, idx and req.state(f, idx) or nil)
      if f.project then
        lines[#lines + 1] = "project:" .. f.project .. "\t" .. tostring(begun[f.project] == true)
      end
      if stage == "doing" or (stage == "idle" and f.project and begun[f.project]) then
        local points = learn.next_points(f.tree, { machine = params.machine, n = params.n })
        if #points > 0 then
          chosen[#chosen + 1] = { f = f, stage = stage, points = points }
        end
      end
    end
    table.sort(chosen, function(a, b)
      if a.stage ~= b.stage then
        return a.stage == "doing"
      end
      local ua, ub = a.f.updated or "", b.f.updated or ""
      if ua ~= ub then
        return ua > ub
      end
      return a.f.id < b.f.id
    end)
    local items = {}
    for _, c in ipairs(chosen) do
      items[#items + 1] = json.object({
        path = c.f.id,
        area = c.f.area,
        title = c.f.title,
        icon = contract.icon_entry(c.f.icon),
        project = c.f.project,
        stage = c.stage,
        points = json.array(vim.tbl_map(function(n)
          return json.object(point_entry(n))
        end, c.points)),
      })
    end
    local doc = contract.head("tasks.learn_next", root)
    doc.machine = params.machine
    doc.items = json.array(items)
    doc.incomplete = incomplete
    return contract.seal(doc, contract.doc.rev_of(lines)), nil
  end)
end

return M
