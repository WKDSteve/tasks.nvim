---@module 'tasks_nvim.learn'
---@brief What the learning views ask of the trees of all paths: the next points to learn, notes and sources, evidence.
---@description
--- Rules the page must not compute (WEB-13), each over one tree (`lernbaum`):
---
---  - `next_points`: the first open points of a tree in document order that may be learned now: a leaf whose mark is
---    open (an unknown mark reads as open, as in `lernbaum`), not blocked, not `{optional}` nor below an optional node,
---    and, with a machine, one it may be practised on (`lernbaum.on_machine`).
---  - `stage_of`: the stage of a node, the root it stands below (itself for a root).
---  - `hours`: the planned, done and open hours of a tree.
---  - `notes`: the points with a note, a link or an image, searched without case.
---  - `evidence`: the points whose label starts with `Nachweis:`, `Aufgabe:` or `Ergebnis:` (`{for=t4}` names the
---    stage they prove).
---
--- Pure Lua, no I/O: `contract_learn` reads the paths.

local lernbaum = require("tasks_nvim.lernbaum")

local M = {}

---The most points `next_points` hands out per path.
M.MAX_NEXT = 20

---The number of points per path when the caller names none.
M.DEFAULT_NEXT = 3

---A sum of hours, kept to two places (`0.1 + 0.2` is `0.3`).
---@param n number
---@return number
local function hours2(n)
  local r = math.floor(n * 100 + 0.5) / 100
  return r == math.floor(r) and math.floor(r) or r
end

---Whether a node above `node` carries the field (`h_min`, `done_h`): then the outer one counts, never both.
---@param node Tasks.LernNode
---@param field string
---@return boolean
local function above_has(node, field)
  local up = node.parent
  while up do
    if up[field] ~= nil then
      return true
    end
    up = up.parent
  end
  return false
end

---Whether every leaf below a node (the node itself for a leaf) is dropped: its hours are no plan any more.
---@param node Tasks.LernNode
---@return boolean
local function all_dropped(node)
  local p = node.progress
  return p ~= nil and p.total > 0 and p.dropped == p.total
end

---The hours of one point: planned (`{h=N}`, `{h=N-M}`), done (`{done_h=N}`) and open (the planned ones of a point not
---closed, less what was done on it, never below 0).
---@param node Tasks.LernNode
---@return { planned_min: number, planned_max: number, done: number, open_min: number, open_max: number }
function M.point_hours(node)
  local pmin, pmax = node.h_min or 0, node.h_max or node.h_min or 0
  if all_dropped(node) then
    pmin, pmax = 0, 0
  end
  local done = node.done_h or 0
  local omin, omax = 0, 0
  if not node.closed then
    omin, omax = math.max(0, pmin - done), math.max(0, pmax - done)
  end
  return {
    planned_min = hours2(pmin),
    planned_max = hours2(pmax),
    done = hours2(done),
    open_min = hours2(omin),
    open_max = hours2(omax),
  }
end

---The hours of a tree: the sum over the outermost points that carry `{h=…}` (planned and open) and the outermost that
---carry `{done_h=…}` (done), optional points left out as everywhere a path says how far it is; nil when no point
---(optional or not) carries hours.
---@param tree Tasks.LernTree
---@return { planned_min: number, planned_max: number, done: number, open_min: number, open_max: number }|nil
function M.hours(tree)
  local any = false
  local sum = { planned_min = 0, planned_max = 0, done = 0, open_min = 0, open_max = 0 }
  for _, node in ipairs(tree and tree.nodes or {}) do
    local planned = node.h_min ~= nil and not above_has(node, "h_min")
    local done = node.done_h ~= nil and not above_has(node, "done_h")
    any = any or node.h_min ~= nil or node.done_h ~= nil
    if not node.in_optional and (planned or done) then
      local h = M.point_hours(node)
      if planned then
        sum.planned_min = sum.planned_min + h.planned_min
        sum.planned_max = sum.planned_max + h.planned_max
        sum.open_min = sum.open_min + h.open_min
        sum.open_max = sum.open_max + h.open_max
      end
      if done then
        sum.done = sum.done + h.done
      end
    end
  end
  if not any then
    return nil
  end
  for k, v in pairs(sum) do
    sum[k] = hours2(v)
  end
  return sum
end

---The root a node stands below (the node itself when it is a root).
---@param node Tasks.LernNode
---@return Tasks.LernNode
function M.stage_of(node)
  local n, up = node, node.parent
  while up do
    n, up = up, up.parent
  end
  return n
end

---Whether a leaf may be learned now: open (or an unknown mark), not optional, on the machine (when one is named).
---@param node Tasks.LernNode
---@param machine? string
---@return boolean
function M.learnable(node, machine)
  if #node.children > 0 or node.in_optional then
    return false
  end
  if (node.state or "open") ~= "open" then
    return false
  end
  return machine == nil or lernbaum.on_machine(node, machine)
end

---The kinds of `notes`: a point with a note (`> ` lines), with a link, with an image.
M.NOTE_KINDS = { "note", "link", "image" }

---Text folded for a search without case (more than ASCII: `Über` finds `über`), as the other searches of the engine.
---@param s string
---@return string
function M.fold(s)
  return vim.fn.tolower(s)
end

---The points of a tree that carry a note, a link or an image (of `kind` only, when given) and, with a `query`
---(already folded, `fold`), whose label, note or link contain it, in document order. Every point counts, a stage
---and an optional one too.
---@param tree Tasks.LernTree
---@param opts? { kind?: "note"|"link"|"image", query?: string }
---@return Tasks.LernNode[]
function M.notes(tree, opts)
  opts = opts or {}
  local out = {}
  for _, node in ipairs(tree and tree.nodes or {}) do
    local has
    if opts.kind then
      has = node[opts.kind] ~= nil
    else
      has = node.note ~= nil or node.link ~= nil or node.image ~= nil
    end
    if has and opts.query and opts.query ~= "" then
      local hay = M.fold(table.concat({ node.label or "", node.note or "", node.link or "" }, "\n"))
      has = hay:find(opts.query, 1, true) ~= nil
    end
    if has then
      out[#out + 1] = node
    end
  end
  return out
end

---The words a point's label starts with when it is evidence (`Nachweis: eine Shell in C`), as `path_schedule` finds
---the result of a session.
M.EVIDENCE_WORDS = { "Nachweis", "Aufgabe", "Ergebnis", "Evidence", "Result" }

---Whether a point is evidence: its label starts with one of `EVIDENCE_WORDS` and a colon (any case).
---@param node Tasks.LernNode
---@return boolean
function M.is_evidence(node)
  local label = vim.trim(node.label or ""):lower()
  for _, w in ipairs(M.EVIDENCE_WORDS) do
    if label:match("^" .. w:lower() .. "%s*:") then
      return true
    end
  end
  return false
end

---The points of a tree that are evidence (`is_evidence`), in document order; an optional one too (it is evidence all
---the same).
---@param tree Tasks.LernTree
---@return Tasks.LernNode[]
function M.evidence(tree)
  local out = {}
  for _, node in ipairs(tree and tree.nodes or {}) do
    if M.is_evidence(node) then
      out[#out + 1] = node
    end
  end
  return out
end

---The first `n` points of a tree that may be learned now, in document order.
---@param tree Tasks.LernTree
---@param opts? { machine?: string, n?: integer }
---@return Tasks.LernNode[]
function M.next_points(tree, opts)
  opts = opts or {}
  local n = opts.n or M.DEFAULT_NEXT
  local out = {}
  for _, node in ipairs(tree and tree.nodes or {}) do
    if #out >= n then
      break
    end
    if M.learnable(node, opts.machine) then
      out[#out + 1] = node
    end
  end
  return out
end

return M
