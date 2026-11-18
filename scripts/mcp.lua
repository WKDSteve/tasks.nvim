---@brief `scripts/mcp.lua` -- the read-only MCP server of the task engine (stdio), for Claude Code and other clients.
---@description
---     nvim --headless -u NONE -l scripts/mcp.lua [--vault=<dir>]
---
--- The vault is `--vault=<dir>`, else `$TASKS_VAULT`. An MCP client starts this as a subprocess and speaks JSON-RPC
--- on its stdin/stdout; run by hand it waits for a line. The tools are `tasks_nvim.mcp`; lib.nvim is found as for
--- `scripts/tasks.lua`.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))

vim.opt.rtp:prepend(plugin_root)

local lib = require("tasks_nvim.boot").find_lib(plugin_root)
if not lib then
  io.stderr:write(
    "error: lib.nvim not found (set LIB_NVIM_DIR, or REPOS_DIR with a lib.nvim checkout)\n"
  )
  os.exit(2)
end
vim.opt.rtp:append(lib)

local root
for i = 1, #(arg or {}) do
  local v = arg[i]:match("^%-%-vault=(.+)$")
  if v then
    root = v
  else
    io.stderr:write(
      ("error: unknown argument %s (usage: scripts/mcp.lua [--vault=<dir>])\n"):format(arg[i])
    )
    os.exit(2)
  end
end

os.exit(require("tasks_nvim.mcp").server({ root = root }):serve())
