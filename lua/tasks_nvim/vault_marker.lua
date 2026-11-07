---@brief The optional marker file `tasks-vault.json` in the root of a vault.
---@description
--- It marks a folder as a "tasks vault" and carries the layout version, extra areas and defaults. Without it every
--- folder works as before. It is a foreign file in a synced vault, so it is read strictly and FAIL CLOSED (SEC-41): an
--- unknown key, a newer version, a link or a file that is not JSON makes the vault unusable with a message that names the
--- file and the reason; nothing is guessed. It holds no data classes, no paths and no code, and `ci.trust_vault_lint` is
--- never read from it.
---
---  - `read(root)`      the file of a vault (`nil` when there is none), or the reason it is refused
---  - `validate(text)`  the rules, a pure function
---  - `write(root, o)`  the one writer (`:TasksVault create`); never over an existing file
---
--- The format is `schemas/tasks-vault/1/tasks-vault.schema.json`; `contract/check.mjs` holds the same rules against it.

local fsio = require("tasks_nvim.fsio")

local M = {}

---The file name, in the root of the vault. A name of its own: a `vault.json` of another tool must not lock a vault.
M.FILE = "tasks-vault.json"

---Version of the file format (`schema`).
M.SCHEMA_VERSION = 1

---Version of the folder layout (`layout_version`); a migration hangs on it later.
M.LAYOUT_VERSION = 1

---Largest file taken (SEC-32).
M.MAX_BYTES = 64 * 1024

---At most this many `extra_areas`.
M.MAX_AREAS = 100

---Every key of the top level. Anything else is refused.
---@type string[]
M.KEYS = { "ci", "extra_areas", "kind", "lang", "layout_version", "plugin", "schema" }

---The keys of `ci`.
---@type string[]
M.CI_KEYS = { "strict" }

M.PLUGIN = "tasks.nvim"
M.KIND = "tasks.vault"

---Body languages of a new task.
---@type string[]
M.LANGS = { "de", "en" }

---What the engine takes from a valid file.
---@class Tasks.VaultMarker
---@field schema integer
---@field layout_version integer
---@field extra_areas string[]
---@field lang? "de"|"en"
---@field ci_strict? boolean

---@param n any
---@return boolean
local function is_int(n)
  return type(n) == "number" and n == math.floor(n) and n >= 1 and n < 2 ^ 31
end

---@param set string[]
---@return string
local function words(set)
  return table.concat(set, ", ")
end

---Text from the file as it may appear in a message: control characters gone, 40 characters at most.
---@param v any
---@return string
local function shown(v)
  local s = fsio.clean(tostring(v))
  return #s > 40 and (s:sub(1, 40) .. "...") or s
end

---@param reason string
---@return nil, string
local function refuse(reason)
  return nil, M.FILE .. ": " .. reason
end

---Check the text of a marker file.
---@param text string
---@return Tasks.VaultMarker|nil marker
---@return string|nil err  starts with `tasks-vault.json:` and names the key or the reason
function M.validate(text)
  if type(text) ~= "string" then
    return refuse("not text")
  end
  if #text > M.MAX_BYTES then
    return refuse(("larger than %d bytes"):format(M.MAX_BYTES))
  end
  local decoded_ok, doc = pcall(vim.json.decode, text)
  if not decoded_ok or type(doc) ~= "table" then
    return refuse("not valid JSON (an object is expected; a merge conflict marker in the file?)")
  end
  -- a JSON array decodes to a table with elements; an object never has integer keys
  if doc[1] ~= nil then
    return refuse("the top level has to be an object, not a list")
  end
  local known = {}
  for _, k in ipairs(M.KEYS) do
    known[k] = true
  end
  for key in pairs(doc) do
    if not known[key] then
      return refuse(("unknown key '%s' (known: %s)"):format(shown(key), words(M.KEYS)))
    end
  end
  for _, key in ipairs({ "schema", "plugin", "kind", "layout_version" }) do
    if doc[key] == nil then
      return refuse(("missing key '%s'"):format(key))
    end
  end
  if doc.plugin ~= M.PLUGIN then
    return refuse(
      ("plugin is '%s', not '%s': the file belongs to another tool"):format(
        shown(doc.plugin),
        M.PLUGIN
      )
    )
  end
  if doc.kind ~= M.KIND then
    return refuse(("kind is '%s', not '%s'"):format(shown(doc.kind), M.KIND))
  end
  if not is_int(doc.schema) then
    return refuse("schema has to be a whole number of 1 or more")
  end
  if doc.schema > M.SCHEMA_VERSION then
    return refuse(
      ("schema %d is newer than this engine knows (%d): update tasks.nvim"):format(
        doc.schema,
        M.SCHEMA_VERSION
      )
    )
  end
  if not is_int(doc.layout_version) then
    return refuse("layout_version has to be a whole number of 1 or more")
  end
  if doc.layout_version > M.LAYOUT_VERSION then
    return refuse(
      ("layout_version %d is newer than this engine knows (%d): update tasks.nvim"):format(
        doc.layout_version,
        M.LAYOUT_VERSION
      )
    )
  end

  local extra = {}
  if doc.extra_areas ~= nil then
    if
      type(doc.extra_areas) ~= "table"
      or (next(doc.extra_areas) ~= nil and not vim.islist(doc.extra_areas))
    then
      return refuse("extra_areas has to be a list of folder names")
    end
    if #doc.extra_areas > M.MAX_AREAS then
      return refuse(("extra_areas holds more than %d names"):format(M.MAX_AREAS))
    end
    local vault = require("tasks_nvim.vault")
    local seen = {}
    for _, name in ipairs(doc.extra_areas) do
      if not vault.valid_area(name) or #name > 100 then
        return refuse(
          ("extra_areas: '%s' is no folder name of the vault (letters, digits, _ . -)"):format(
            shown(name)
          )
        )
      end
      if seen[name] then
        return refuse(("extra_areas: '%s' is listed twice"):format(name))
      end
      seen[name] = true
      extra[#extra + 1] = name
    end
  end

  if doc.lang ~= nil and doc.lang ~= "de" and doc.lang ~= "en" then
    return refuse(("lang '%s' is none of %s"):format(shown(doc.lang), words(M.LANGS)))
  end

  local strict
  if doc.ci ~= nil then
    if type(doc.ci) ~= "table" or doc.ci[1] ~= nil then
      return refuse("ci has to be an object")
    end
    for key in pairs(doc.ci) do
      if key ~= "strict" then
        return refuse(("unknown key 'ci.%s' (known: %s)"):format(shown(key), words(M.CI_KEYS)))
      end
    end
    if doc.ci.strict ~= nil then
      if type(doc.ci.strict) ~= "boolean" then
        return refuse("ci.strict has to be true or false")
      end
      strict = doc.ci.strict
    end
  end

  return {
    schema = doc.schema,
    layout_version = doc.layout_version,
    extra_areas = extra,
    lang = doc.lang,
    ci_strict = strict,
  },
    nil
end

---The path of the marker file of a vault.
---@param root string
---@return string
function M.path(root)
  return root .. "/" .. M.FILE
end

---Read the marker of a vault. One read per read scope.
---@param root string
---@return Tasks.VaultMarker|nil marker  `nil`: there is no file, or it is refused (`err` tells)
---@return string|nil err                the reason the file is refused; `nil` when it is absent or valid
function M.read(root)
  local result = fsio.scope_memo("marker:" .. root, function()
    local path = M.path(root)
    local st = fsio.lstat(path)
    if not st then
      return { absent = true }
    end
    if st.type == "link" then
      local _, err = refuse("is a link (a symbolic link or a junction is a way out of the vault)")
      return { err = err }
    end
    if st.type ~= "file" then
      local _, err = refuse("is not a regular file")
      return { err = err }
    end
    local text = fsio.read(path)
    if not text then
      local _, err = refuse("cannot be read")
      return { err = err }
    end
    local marker, err = M.validate(text)
    if not marker then
      return { err = err }
    end
    return { marker = marker }
  end)
  return result.marker, result.err
end

---What a reader (the contract's `hello`, `health`) wants to know in one table.
---@param root string
---@return { present: boolean, layout_version?: integer, problem?: string }
function M.status(root)
  local marker, err = M.read(root)
  if marker then
    return { present = true, layout_version = marker.layout_version }
  end
  if err then
    return { present = true, problem = err }
  end
  return { present = false }
end

---The text of a marker file: sorted keys, two-space indent, a final newline. It is there to be edited by a person.
---@param o? { extra_areas?: string[], lang?: "de"|"en", ci_strict?: boolean }
---@return string
function M.render(o)
  o = o or {}
  local lines = {}
  local function add(line)
    lines[#lines + 1] = line
  end
  local entries = {}
  if o.ci_strict ~= nil then
    entries[#entries + 1] = ('  "ci": {\n    "strict": %s\n  }'):format(
      o.ci_strict and "true" or "false"
    )
  end
  if o.extra_areas and #o.extra_areas > 0 then
    local names = {}
    for _, name in ipairs(o.extra_areas) do
      names[#names + 1] = "    " .. vim.json.encode(name)
    end
    entries[#entries + 1] = '  "extra_areas": [\n' .. table.concat(names, ",\n") .. "\n  ]"
  end
  entries[#entries + 1] = ('  "kind": %s'):format(vim.json.encode(M.KIND))
  if o.lang then
    entries[#entries + 1] = ('  "lang": %s'):format(vim.json.encode(o.lang))
  end
  entries[#entries + 1] = ('  "layout_version": %d'):format(M.LAYOUT_VERSION)
  entries[#entries + 1] = ('  "plugin": %s'):format(vim.json.encode(M.PLUGIN))
  entries[#entries + 1] = ('  "schema": %d'):format(M.SCHEMA_VERSION)
  add("{")
  add(table.concat(entries, ",\n"))
  add("}")
  return table.concat(lines, "\n") .. "\n"
end

---Write the marker of a new vault. Never over a file that is there (a person edits it; the engine does not). The
---result has to pass `validate`.
---@param root string
---@param o? { extra_areas?: string[], lang?: "de"|"en", ci_strict?: boolean }
---@return boolean|nil ok
---@return string|nil err  `"exists"` when there is a file already
function M.write(root, o)
  local path = M.path(root)
  if fsio.lstat(path) then
    return nil, fsio.EXISTS
  end
  local text = M.render(o)
  local marker, err = M.validate(text)
  if not marker then
    return nil, err
  end
  local ok, werr = fsio.write_atomic(path, text)
  if not ok then
    return nil, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true, nil
end

return M
