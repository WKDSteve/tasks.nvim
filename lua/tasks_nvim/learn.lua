---@module 'tasks_nvim.learn'
---@brief What the learning views ask of the trees of all paths: the next points to learn, notes and sources, evidence.
---@description
--- Rules the page must not compute (WEB-13), each over one tree (`lernbaum`):
---
---  - `next_points`: the first open points of a tree in document order that may be learned now: a leaf whose mark is
---    open (an unknown mark reads as open, as in `lernbaum`), not blocked, not `{optional}` nor below an optional node,
---    and, with a machine, one it may be practised on (`lernbaum.on_machine`).
---  - `stage_of`: the stage of a node, the root it stands below (itself for a root).
---
--- Pure Lua, no I/O: `contract_learn` reads the paths.

local lernbaum = require("tasks_nvim.lernbaum")

local M = {}

---The most points `next_points` hands out per path.
M.MAX_NEXT = 20

---The number of points per path when the caller names none.
M.DEFAULT_NEXT = 3

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
