-- TESTS/tasks_mcp_stdio_spec.lua -- scripts/mcp.lua as a real process, talked to by the MCP client of lib.nvim with
-- stdin held open: the boot (lib.nvim found, --vault read), the handshake and one tool, as Claude Code would.
-- @scans-data (what it lists is a fixture vault in a temp folder)

return function(H)
  local eq, ok = H.eq, H.ok
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local root_dir = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(here, ":p")))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local vault = fixture.build(H)

  local lib = vim.api.nvim_get_runtime_file("lua/lib/nvim/mcp/server/init.lua", false)[1]
  ok(lib, "lib.nvim with lib.nvim.mcp.server is on the runtimepath")
  local lib_dir = vim.fs.normalize(lib):gsub("/lua/lib/nvim/mcp/server/init%.lua$", "")

  local c = require("lib.nvim.mcp").client({
    id = "tasks-mcp-stdio-spec",
    cmd = {
      vim.v.progpath,
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      "NONE",
      "-l",
      root_dir .. "/scripts/mcp.lua",
      "--vault=" .. vault,
    },
    -- NVIM cleared: inside the runner it names the parent editor
    env = { NVIM = "", NVIM_LISTEN_ADDRESS = "", LIB_NVIM_DIR = lib_dir },
    timeout_ms = 20000,
  })
  local function ask(fn)
    local done, a, b = false, nil, nil
    fn(function(x, y)
      done, a, b = true, x, y
    end)
    vim.wait(25000, function()
      return done
    end, 10)
    return a, b
  end

  local tools, err = ask(function(cb)
    c:list_tools(cb)
  end)
  ok(tools and not err, "tools/list over stdio: " .. vim.inspect(err))
  eq(tools and #tools, 11, "eleven read tools (paths and path among them)")
  eq((c:server() or {}).serverInfo.name, "tasks.nvim", "the handshake reached scripts/mcp.lua")
  local res = ask(function(cb)
    c:call_tool("tasks_list", { limit = 3 }, cb)
  end)
  ok(res and not res.isError, "tasks_list over stdio answers")
  eq(
    res and vim.json.decode(res.content[1].text).kind,
    "tasks.list",
    "the document of the fixture vault"
  )
  c:stop()
end
