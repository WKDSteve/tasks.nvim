-- TESTS/tasks_static_requires_spec.lua -- every `require` under lua/ names its module as a literal.
-- A computed name (`require(name)`, `pcall(require, name)`, `require("tasks_nvim." .. key)`) leaves the module
-- graph of docmap.nvim without an edge, so it has to assume the loader reaches anything: `testing run --changed`
-- then answers `complete = false` and runs every spec. soft.lua is the probe of optional plugins; its callers do
-- the `require` themselves.

return function(H)
  local eq, ok = H.eq, H.ok
  local root =
    vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

  ---The `require` calls of a source whose first argument is not a plain string literal.
  ---@param src string
  ---@return string[] found one "line N: text" per computed require
  local function computed(src)
    local found = {}
    local n = 0
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
      n = n + 1
      if not line:match("^%s*%-%-") then
        local code = line:gsub("%-%-.*$", "")
        local pos = 1
        while true do
          local s, e = code:find("require", pos, true)
          if not s then
            break
          end
          pos = e + 1
          local before, after = code:sub(s - 1, s - 1), code:sub(e + 1, e + 1)
          if not before:match("[%w_]") and not after:match("[%w_]") then
            local rest = code:sub(e + 1)
            local arg = rest:match("^%s*%(%s*(.*)")
            if not arg and code:sub(1, s - 1):match("pcall%s*%(%s*$") then
              arg = rest:match("^%s*,%s*(.*)")
            end
            -- a literal that is the whole argument: `"name")` or `"name",` (pcall); anything else is computed
            if arg and arg ~= "" and not arg:match("^([\"'])[^\"']*%1%s*[%),]") then
              found[#found + 1] = ("line %d: %s"):format(n, vim.trim(line))
            end
          end
        end
      end
    end
    return found
  end

  -- ── the scan finds the computed forms docmap cannot follow ──
  -- REQ stands for the word: written out, these samples would make this spec a computed loader to docmap
  local function count(sample)
    return #computed((sample:gsub("REQ", "require")))
  end
  eq(count('local m = REQ("tasks_nvim.scan")'), 0)
  eq(count('local ok, m = pcall(REQ, "snacks")'), 0)
  eq(count("-- local m = REQ(name)"), 0, "a comment line is no call")
  eq(count("local m = REQ(name)"), 1)
  eq(count("local ok, m = pcall(REQ, req[1])"), 1)
  eq(count('local m = REQ("tasks_nvim." .. key)'), 1)
  eq(count("local ok = pcall(req[3])"), 0, "a loader function is no require")

  -- ── no module under lua/ requires by a computed name ──
  local files = vim.fs.find(function(name)
    return name:match("%.lua$") ~= nil
  end, { path = root .. "/lua", type = "file", limit = math.huge })
  ok(#files > 20, "the scan reads the plugin's modules")
  local bad = {}
  for _, file in ipairs(files) do
    local f = assert(io.open(file, "rb"))
    local src = f:read("*a")
    f:close()
    for _, hit in ipairs(computed(src)) do
      bad[#bad + 1] = file:sub(#root + 2) .. " " .. hit
    end
  end
  eq(bad, {}, "computed requires (see the header of this spec)")

  -- ── soft.check: the module when it is a table with every field, nil otherwise ──
  local soft = require("tasks_nvim.soft")
  local mod = { form = function() end }
  eq(soft.check({ "form" }, true, mod), mod)
  eq(soft.check(nil, true, mod), mod)
  eq(soft.check({ "form", "missing" }, true, mod), nil, "an older plugin without the call")
  eq(soft.check(nil, false, "module 'x' not found"), nil, "a missing plugin")
  eq(soft.check(nil, true, true), nil, "a module that is no table")
  eq(soft.check(nil, pcall(require, "tasks_nvim_no_such_module")), nil)
  ok(soft.check({ "check" }, pcall(require, "tasks_nvim.soft")) ~= nil)
end
