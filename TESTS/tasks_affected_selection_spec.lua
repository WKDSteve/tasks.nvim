-- TESTS/tasks_affected_selection_spec.lua -- `testing run --changed` selects some specs, not all of them.
-- A computed require (tasks_static_requires_spec.lua) and a vault scanner without `-- @scans-data` (a module that
-- lists folders and names `README.md` or `assets/`, which this repository has as well) each made a change of any
-- module reach every spec. The built-in heuristic of testing.nvim answers the same question without docmap.nvim.

return function(H)
  local eq, ok = H.eq, H.ok
  local root =
    vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  local has_affected, affected = pcall(require, "testing.affected")
  ok(has_affected, "testing.nvim runs this suite, so testing.affected is on the runtime path")

  local specs = {}
  for name, kind in vim.fs.dir(root .. "/TESTS") do
    if kind == "file" and name:match("_spec%.lua$") then
      specs[#specs + 1] = "TESTS/" .. name
    end
  end
  table.sort(specs)
  ok(#specs > 50, "the suite is found")

  local r = affected.select({
    root = root,
    specs = specs,
    changed = { "lua/tasks_nvim/api.lua" },
    provider = false,
    roots = { "TESTS" },
    no_cache = true,
    getenv = function()
      return nil
    end,
  })
  eq(r.all, false, tostring(r.all_reason))
  eq(r.source, "heuristic")
  -- 94 of 167 on 2026-11-21 (91 of 164 before three new specs of the command line, which reach api.lua through
  -- cli.lua by nature: the share grows with such specs, not with a new edge); 62 of 115 on 2026-11-16; 60 of 111 on
  -- 2026-11-12 (70 before the specs that list a temp vault declared `-- @scans-data`, 109 before the vault scanners did)
  ok(
    #r.files <= #specs * 0.58,
    ("%d of %d specs: a change of api.lua reaches nearly every spec"):format(#r.files, #specs)
  )

  -- the specs that list the project itself (TESTS/, lua/) never declare `-- @scans-data`: whatever changes, they stay
  -- in the selection, for the reason that they list it (a directive there would hide a change from them)
  local chosen = {}
  for _, f in ipairs(r.files) do
    chosen[f] = true
  end
  for _, spec in ipairs({
    "TESTS/tasks_static_requires_spec.lua",
    "TESTS/tasks_affected_selection_spec.lua",
  }) do
    local f = assert(io.open(root .. "/" .. spec, "rb"))
    local text = f:read("*a")
    f:close()
    ok(not text:find("\n%-%- @scans%-data"), spec .. " reads the project: no -- @scans-data")
    ok(chosen[spec], spec .. " is selected for a change of api.lua")
    ok(
      tostring(r.reason[spec]):find("lists directories", 1, true) ~= nil,
      spec .. ": " .. tostring(r.reason[spec])
    )
  end

  -- the vault scanners say what they list: no seed of every change
  for _, mod in ipairs({ "check", "cli", "scan", "claims", "vault_ops", "wikilinks" }) do
    local f = assert(io.open(root .. "/lua/tasks_nvim/" .. mod .. ".lua", "rb"))
    local head = f:read(400)
    f:close()
    ok(head:find("\n%-%- @scans%-data") ~= nil, mod .. ".lua declares -- @scans-data")
  end
end
