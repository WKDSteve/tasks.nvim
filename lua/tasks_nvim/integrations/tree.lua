---@module 'tasks_nvim.integrations.tree'
---@brief The task vault in a tree view: a count of open tasks on the area folders, a view `tasks`, and "finish" / "claim" on a task.
---@description
--- Registers four entries at `lib.nvim.tree.registry`. A tree that reads the registry (the own tree of
--- filetree.nvim) then shows:
---
---  - a decorator `tasks`: next to an area folder of the vault, its `ROADMAP` and its `ROADMAP/tasks`
---    the number of open tasks. The number comes from the generated index
---    (`tasks_nvim.integrations.tree_counts`), never from a scan while the tree draws
---  - a source `tasks`: the areas that have open tasks, below each its tasks in the order of the index.
---    A task node carries the path of its file, so opening, preview and the path actions of the tree
---    work on it. Without a vault the view says why it is empty
---  - two actions, `tasks.done` and `tasks.claim`, on every node that is a task: a node of the view,
---    or the task file in the plain file view. They run what `:Tasks done` and `:Tasks claim` run,
---    the question before finishing included
---
--- Soft in both directions. The registry is lib.nvim's: without a tree that reads it the entries are
--- never looked at, and without a lib.nvim that has the registry nothing is registered. The task files
--- of an area are read when its node is opened, the index heads when a tree starts to show badges.

local counts = require("tasks_nvim.integrations.tree_counts")
local soft = require("tasks_nvim.soft")
local vault = require("tasks_nvim.vault")

local M = {}

M.DECORATOR = "tasks"
M.SOURCE = "tasks"
M.ACTION_DONE = "tasks.done"
M.ACTION_CLAIM = "tasks.claim"

---@class Tasks.Tree.Opts
---@field keys? { done?: string|string[]|false, claim?: string|string[]|false }  Keys in the tree buffer (default: none; the actions are in the menu).

---@type fun()[]
local removers = {}

---The id of the task a node stands for, or nil: a node of the `tasks` view, or a file
---`<vault>/<area>/ROADMAP/tasks/<slug>.md` (a folder task: `<slug>/<slug>.md`) in any view. A text
---test, no file access.
---@param node table|nil
---@return string|nil id
function M.task_id(node)
  if type(node) ~= "table" then
    return nil
  end
  if type(node.data) == "table" and type(node.data.task_id) == "string" then
    return node.data.task_id
  end
  if type(node.path) ~= "string" then
    return nil
  end
  -- the vault of this moment, not the one the counts were read for: the commands the actions run ask
  -- the same way (`unchecked`: the folder only, this is asked per node and action)
  local root = vault.root({ unchecked = true })
  if not root then
    return nil
  end
  local path, prefix = counts.norm(node.path), counts.norm(root) .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local area, rest = path:sub(#prefix + 1):match("^([^/]+)/ROADMAP/tasks/(.+)%.md$")
  if not area then
    return nil
  end
  local slug = rest
  local folder, file = rest:match("^([^/]+)/([^/]+)$")
  if folder then
    if folder ~= file then
      return nil
    end
    slug = folder
  end
  if not (vault.valid_area(area) and vault.valid_slug(slug)) then
    return nil
  end
  return area .. "/" .. slug
end

---The task ids of the nodes handed to an action, in order, each once.
---@param nodes table[]|nil
---@return string[]
local function ids_of(nodes)
  local out, seen = {}, {}
  for _, node in ipairs(nodes or {}) do
    local id = M.task_id(node)
    if id and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

---What `:Tasks <verb> <id>` hands its handler.
---@param id string
---@return table
local function ctx_for(id)
  return { args = { id = id }, kv = {}, flags = {}, rest = {} }
end

---Finish the first task of `nodes` like `:Tasks done <id>` (it asks first). Finishing asks a
---question per task, so with several marked only the first is finished, and that is said.
---@param nodes table[]
function M.done(nodes)
  local ids = ids_of(nodes)
  if #ids == 0 then
    return
  end
  if #ids > 1 then
    vim.notify(
      ("[tasks] %d tasks are marked; finishing the first only: %s"):format(#ids, ids[1]),
      vim.log.levels.WARN
    )
  end
  require("tasks_nvim.ui.cmd").task_done(ctx_for(ids[1]))
end

---Claim every task of `nodes` like `:Tasks claim <id>`.
---@param nodes table[]
function M.claim(nodes)
  for _, id in ipairs(ids_of(nodes)) do
    require("tasks_nvim.ui.cmd").task_claim(ctx_for(id))
  end
end

---The open tasks of an area as nodes, in the order of the index.
---@param root string
---@param area string
---@return table[]|nil nodes
---@return string|nil err
local function task_nodes(root, area)
  local scan = require("tasks_nvim.scan")
  local model = require("tasks_nvim.model")
  local tasks, err = scan.open_tasks({ root = root, area = area })
  if not tasks then
    return nil, tostring(err)
  end
  local open = {}
  for _, task in ipairs(tasks) do
    if task.location == "roadmap" then
      open[#open + 1] = task
    end
  end
  local out = {}
  for _, task in ipairs(model.sort(open)) do
    out[#out + 1] = {
      id = "tasks:" .. task.id,
      label = task.title,
      kind = "task",
      path = task.path,
      columns = { task.status },
      data = { task_id = task.id },
    }
  end
  return out
end

---The root node of the view: the areas with open tasks.
---@return table
function M.root_node()
  local root = vault.root()
  return {
    id = "tasks:root",
    label = "Tasks",
    kind = "root",
    children = function(_, cb)
      if not root then
        cb({})
        return
      end
      -- a view that is shown without the decorator having read the vault (no badges drawn yet)
      if counts.root() ~= root then
        counts.refresh(true)
      end
      local out = {}
      for _, area in ipairs(counts.areas()) do
        out[#out + 1] = {
          id = "tasks:" .. area.name,
          label = area.name,
          kind = "group",
          -- its folder: the decorator above draws the count next to it, in this view as in any other
          path = root .. "/" .. area.name,
          children = function(_, cb_tasks)
            local nodes, err = task_nodes(root, area.name)
            cb_tasks(nodes, err)
          end,
        }
      end
      if #out == 0 then
        out[1] = { id = "tasks:none", label = "no open tasks", kind = "note" }
      end
      cb(out)
    end,
  }
end

---Whether the view can load: `false` and the reason without a vault.
---@return boolean
---@return string|nil reason
function M.available()
  local root, err = vault.root()
  if not root then
    return false, err
  end
  return true
end

---@param key any
---@return string|string[]|nil
local function key_of(key)
  if type(key) == "string" or type(key) == "table" then
    return key
  end
  return nil
end

---Register the decorator, the view and the two actions. Without `lib.nvim.tree.registry` (an older
---lib.nvim) nothing happens.
---@param opts? Tasks.Tree.Opts
---@return boolean registered
function M.register(opts)
  local registry =
    soft.check({ "decorator", "source", "action" }, pcall(require, "lib.nvim.tree.registry"))
  if not registry then
    return false
  end
  M.unregister()
  local keys = type(opts) == "table" and type(opts.keys) == "table" and opts.keys or {}

  removers[#removers + 1] = registry.decorator({
    name = M.DECORATOR,
    key = "path",
    slot = "badge",
    priority = 30,
    roll_up = false,
    get = function(path)
      return counts.badge(path)
    end,
    all = function()
      return counts.badges()
    end,
    subscribe = function(emit)
      return counts.on_change(function(event)
        if event.counts then
          emit(event.paths)
        end
      end)
    end,
  })

  removers[#removers + 1] = registry.source({
    name = M.SOURCE,
    title = "Tasks",
    mutable = false,
    root = M.root_node,
    available = M.available,
    subscribe = function(_, emit)
      return counts.on_change(function()
        emit.reset()
      end)
    end,
  })

  local function is_task(node)
    return M.task_id(node) ~= nil
  end
  removers[#removers + 1] = registry.action({
    name = M.ACTION_DONE,
    desc = "Finish this task (tasks.nvim)",
    key = key_of(keys.done),
    when = is_task,
    mutates = true,
    run = M.done,
  })
  removers[#removers + 1] = registry.action({
    name = M.ACTION_CLAIM,
    desc = "Claim this task while you work on it (tasks.nvim)",
    key = key_of(keys.claim),
    when = is_task,
    mutates = true,
    run = M.claim,
  })
  return true
end

---Take the entries out again.
function M.unregister()
  for _, remove in ipairs(removers) do
    pcall(remove)
  end
  removers = {}
end

return M
