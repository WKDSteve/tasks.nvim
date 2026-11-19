-- TESTS/tasks_mcp_spec.lua -- tasks_nvim.mcp: the read methods of tasks-export/1 as MCP tools.
-- @scans-data (what it lists is a fixture vault in a temp folder)

return function(H)
  local eq, ok = H.eq, H.ok
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local fixture = dofile(here .. "/contract_fixture.lua")
  local tmcp = require("tasks_nvim.mcp")

  local root = fixture.build(H)
  local server = tmcp.server({ root = root })

  local function send(msg)
    return vim.json.decode(server:dispatch(vim.json.encode(msg)))
  end

  -- the catalogue: reads only, the write door is not there
  local res = send({ jsonrpc = "2.0", id = 1, method = "tools/list" })
  local names = {}
  for _, t in ipairs(res.result.tools) do
    names[t.name] = t
  end
  ok(names.tasks_list and names.tasks_task and names.tasks_check, "list, show and check are tools")
  ok(names.tasks_paths and names.tasks_path, "the learning paths are read tools")
  eq(names.tasks_path.inputSchema.required[1], "id", "tasks_path requires an id")
  ok(
    not names.tasks_promote and not names.tasks_node_set and not names.tasks_path_new,
    "the writes of the learning paths are no tools"
  )
  ok(not names.tasks_ops, "the write door ops is no tool")
  ok(
    not names.tasks_intent and not names.tasks_done_preview,
    "intent and done_preview are no tools"
  )
  eq(names.tasks_task.inputSchema.required[1], "id", "tasks_task requires an id")

  -- one call through the whole path: JSON-RPC in, the contract's document out
  res = send({
    jsonrpc = "2.0",
    id = 2,
    method = "tools/call",
    params = { name = "tasks_list", arguments = { limit = 5 } },
  })
  ok(not res.result.isError, "tasks_list answers a document")
  local doc = vim.json.decode(res.result.content[1].text)
  eq(doc.kind, "tasks.list", "the document is a tasks.list")
  ok(#doc.items >= 1 and #doc.items <= 5, "the page holds tasks, at most the limit")

  -- an error document of the contract reaches the model as isError
  res = send({
    jsonrpc = "2.0",
    id = 3,
    method = "tools/call",
    params = { name = "tasks_list", arguments = { limit = 0 } },
  })
  ok(res.result.isError, "a bad argument is an isError result")
  eq(
    vim.json.decode(res.result.content[1].text).code,
    "invalid_argument",
    "with the contract's code"
  )
end
