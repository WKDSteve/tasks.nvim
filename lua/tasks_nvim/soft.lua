---@module 'tasks_nvim.soft'
---@brief The one place that asks "is this optional plugin there, and does it have what we call?".
---@description
--- tasks.nvim works without snacks.nvim, ui.nvim, pickers.nvim, cascade.nvim, mdview.nvim and the newer
--- lib.nvim submodules; each of them is probed here, with the fields the caller is about to use, so a missing
--- plugin and an older plugin that lacks the function look the same (not available) and the caller falls back.
--- `health.lua` deliberately does NOT use this: it reports what `require` really says.
---
--- The caller does the `require` itself, with the module name as a literal:
---
---   local kit = soft.check({ "form" }, pcall(require, "ui.kit"))
---
--- so the module graph (docmap.nvim, `testing run --changed`) sees every edge. A loader that took the name
--- as a value would be a computed require, and the graph would have to assume it loads anything.

local M = {}

---@param fields string[]|nil        fields that must exist (the calls the caller is about to make)
---@param ok boolean                 the first result of `pcall(require, "<name>")`
---@param mod any                    the second result
---@return table|nil mod             nil when the module is missing, no table, or lacks a field
function M.check(fields, ok, mod)
  if not ok or type(mod) ~= "table" then
    return nil
  end
  for _, field in ipairs(fields or {}) do
    if mod[field] == nil then
      return nil
    end
  end
  return mod
end

return M
