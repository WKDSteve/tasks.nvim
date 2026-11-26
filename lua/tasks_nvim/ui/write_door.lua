---@module 'tasks_nvim.ui.write_door'
---@brief One operation through the write door (`tasks_nvim.ops`) from a command of the editor, with its failure said.
---@description
--- The editor's commands that write through `tasks-ops/1` (`:Tasks meeting ...`, `:Tasks checklist ...`) send one
--- operation at a time and tell the person when it fails; this is that one step, so they all say it the same way.
---
--- Not its job: the operations themselves (`ops`), asking before a write (`ui.confirm`).

local notify = require("lib.nvim.notify").create("[tasks]")

local M = {}

---Send one operation through the write door; its result entry, or nil after a message.
---@param op table
---@return table|nil entry
function M.run(op)
  -- the head of the answer names the engine's commit: asked in the background, the editor never waits for git
  require("tasks_nvim.contract").prewarm()
  local doc, err = require("tasks_nvim.ops").run({ ops = { op } }, {})
  if not doc then
    notify.error(tostring(type(err) == "table" and err.message or err))
    return nil
  end
  local entry = doc.results[1]
  if not entry.ok then
    notify.error(tostring(entry.error.message))
    return nil
  end
  return entry
end

return M
