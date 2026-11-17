---@module 'tasks_nvim.vault'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Where the task vault is, which areas it has, and every path the task system uses.
---@description
--- The vault is a folder you name (`setup({ vault = ... })`, `$TASKS_VAULT` or `--vault`): one
--- folder per area (the units of work: a repo, a plugin, an app), each with `ROADMAP/` (open) and `Backlog/` (done).
--- This module is the only place that knows that layout.
---
--- Key responsibilities:
---  - resolve the vault root (explicit option, `set_root`, `configure`, `$TASKS_VAULT`),
---    so a spec can point everything at a fixture; there is no built-in default path
---  - list the areas: every folder holding `ROADMAP/` or `Backlog/`, plus the
---    named extras; `_`-prefixed folders, `TEMPLATES` and `TOOLS` are skipped
---  - build the paths (`ROADMAP/tasks`, `ROADMAP/TASKS.md`, `Backlog/<bucket>`)
---  - validate area names, slugs and ids before they become part of a path
---
--- Not its job: reading task files (`scan`/`model`) or writing anything.

local fsio = require("tasks_nvim.fsio")

local uv = vim.uv or vim.loop

local M = {}

---Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`
---(set with `configure({ extra_areas = ... })`; empty by default).
---@type string[]
M.EXTRA_AREAS = {}

---Folders that are never areas.
---@type table<string, boolean>
M.SKIP = { TEMPLATES = true, TOOLS = true }

---`kind` -> where `done` moves the file (rule R6).
---@type table<string, Tasks.Bucket>
M.BUCKET_OF_KIND = {
  feature = "FEATURES",
  idea = "FEATURES",
  research = "FEATURES",
  task = "TASKS",
  bug = "TASKS",
}

---@type string|nil
local override_root

---@type string|nil
local configured_root

---The named vaults of `configure({ vaults })`: name -> normalised path.
---@type table<string, string>
local named = {}

---The name of the active named vault (`nil`: the vault is a plain path, `$TASKS_VAULT` or none).
---@type string|nil
local active_name

---Apply the user's options (called by `tasks_nvim.setup`). Only the keys that are present change anything.
---
---`vaults = { main = "<dir>", other = "<dir>" }` names several vaults; `vault` then may be one of the
---names (a path of that spelling is only taken when no name matches). Without `vault` the first name
---(sorted) is active. A name that is not a plain word or a path that is not a string is dropped.
---
---`vault_rules = { { match = "<dir>", vault = "<name>" } }` picks the vault by the working directory:
---the first rule whose `match` is the cwd or a folder above it wins over `vault` (the cwd is read once, here).
---@param opts? { vault?: string, vaults?: table<string, string>, vault_rules?: Tasks.VaultRule[], extra_areas?: string[], cwd?: string }
---@return nil
function M.configure(opts)
  opts = opts or {}
  local vaults_given = type(opts.vaults) == "table"
  if vaults_given then
    named = {}
    for name, path in pairs(opts.vaults) do
      if M.valid_area(name) and type(path) == "string" and path ~= "" then
        named[name] = fsio.norm(path)
      end
    end
    -- a name the new set no longer has must not stay "active" (the root it set stays until `vault` says otherwise)
    if active_name and not named[active_name] then
      active_name = nil
    end
  end
  if opts.vault ~= nil then
    local want = opts.vault
    if type(want) == "string" and named[want] then
      active_name, configured_root = want, named[want]
    else
      active_name = nil
      configured_root = (type(want) == "string" and want ~= "") and fsio.norm(want) or nil
    end
  end
  if vaults_given and opts.vault == nil then
    local first = M.vault_names()[1]
    if first then
      active_name, configured_root = first, named[first]
    end
  end
  if type(opts.vault_rules) == "table" and #opts.vault_rules > 0 then
    local picked = M.for_cwd(opts.cwd or vim.uv.cwd(), opts.vault_rules)
    if picked then
      active_name, configured_root = picked, named[picked]
    end
  end
  if type(opts.extra_areas) == "table" then
    M.EXTRA_AREAS = vim.deepcopy(opts.extra_areas)
  end
end

---@class Tasks.VaultRule
---@field match string  A folder; the rule applies when the working directory is that folder or lies below it.
---@field vault string  The name of a vault of `vaults`.

---The named vault a working directory selects: the first rule whose folder contains `cwd` and whose vault is
---named. A rule for a name `vaults` does not have is skipped (the next rule may still match).
---@param cwd? string
---@param rules Tasks.VaultRule[]
---@return string|nil name
function M.for_cwd(cwd, rules)
  if type(cwd) ~= "string" or cwd == "" or type(rules) ~= "table" then
    return nil
  end
  for _, rule in ipairs(rules) do
    if
      type(rule) == "table"
      and type(rule.match) == "string"
      and rule.match ~= ""
      and type(rule.vault) == "string"
      and named[rule.vault]
      and fsio.is_inside(rule.match, cwd)
    then
      return rule.vault
    end
  end
  return nil
end

---The names of the configured vaults, sorted.
---@return string[]
function M.vault_names()
  local out = {}
  for name in pairs(named) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

---The name of the active vault, `nil` when it is a plain path, `$TASKS_VAULT` or none.
---@return string|nil
function M.active_name()
  return active_name
end

---The configured name of the vault at `root`, `nil` when it has none (a plain path, or no names configured).
---@param root string
---@return string|nil
function M.name_of(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local want = fsio.norm(root)
  for _, name in ipairs(M.vault_names()) do
    if named[name] == want then
      return name
    end
  end
  return nil
end

---Make a named vault the one this session works on. Dashboards opened later follow, and so do open ones
---(`ui.dash.follow_vault`, called by `:TasksVault switch`).
---@param name string
---@return string|nil root  the new root
---@return string|nil err   unknown name, or the folder is gone (the active vault is then unchanged)
function M.switch(name)
  local path = named[name]
  if not path then
    local names = M.vault_names()
    return nil,
      ("unknown vault '%s'%s"):format(
        tostring(name),
        #names > 0 and (" (known: " .. table.concat(names, ", ") .. ")") or " (setup() names none)"
      )
  end
  local root, err = M.root({ root = path })
  if not root then
    return nil, err
  end
  active_name, configured_root = name, path
  return root, nil
end

---The named extras: `configure({ extra_areas })`, `$TASKS_EXTRA_AREAS` (comma separated; the headless CLI has
---no `setup`, so this is how it learns them) and, with a `root`, the `extra_areas` of the vault's marker file
---`tasks-vault.json`. The union, a name once.
---@param root? string
---@return string[]
function M.extra_areas(root)
  local out = vim.list_extend({}, M.EXTRA_AREAS)
  local env = vim.env.TASKS_EXTRA_AREAS
  if env and env ~= "" then
    for name in env:gmatch("[^,]+") do
      out[#out + 1] = vim.trim(name)
    end
  end
  if root then
    -- an invalid marker never gets this far: `root()` refuses the vault first
    local marker = require("tasks_nvim.vault_marker").read(root)
    for _, name in ipairs(marker and marker.extra_areas or {}) do
      if not vim.tbl_contains(out, name) then
        out[#out + 1] = name
      end
    end
  end
  return out
end

---Pin the vault root for this process (nil clears it). Used by specs.
---@param path string|nil
---@return nil
function M.set_root(path)
  override_root = path and fsio.norm(path) or nil
end

---Resolve the vault root. Order: `opts.root`, `set_root`, `configure`, `$TASKS_VAULT`.
---
---A vault with a marker file `tasks-vault.json` that is refused (unknown key, newer version, not JSON) is no vault:
---the answer is `nil, "tasks-vault.json: <reason>"` (fail closed). `opts.unchecked` skips that, for the one caller
---that has to report the problem (`contract.hello`).
---@param opts? { root?: string, unchecked?: boolean }
---@return string|nil root  forward slashes, no trailing slash
---@return string|nil err
function M.root(opts)
  local candidate = opts and opts.root
  if not candidate or candidate == "" then
    candidate = override_root
  end
  if not candidate or candidate == "" then
    candidate = configured_root
  end
  if not candidate or candidate == "" then
    local env_root = vim.env.TASKS_VAULT
    if env_root and env_root ~= "" then
      candidate = env_root
    end
  end
  if not candidate or candidate == "" then
    return nil, "vault not found: call setup({ vault = <dir> }), set $TASKS_VAULT, or pass --vault"
  end
  -- A NUL cuts the path for libuv (`fs_stat` sees what is before it) but not for Lua: the
  -- vault would look like a directory, and a walk below it rescans that directory for ever.
  if candidate:find("\0", 1, true) then
    return nil, "vault path holds a NUL byte"
  end
  candidate = fsio.norm(candidate)
  if not fsio.is_dir(candidate) then
    return nil, "vault is not a directory: " .. candidate
  end
  if not (opts and opts.unchecked) then
    local _, merr = require("tasks_nvim.vault_marker").read(candidate)
    if merr then
      return nil, merr
    end
  end
  return candidate, nil
end

---Names Windows treats as devices, in any case and with or without an
---extension (`NUL`, `con.txt`). A file called like one is no file there: writing
---it succeeds and stores nothing (`nul`), or fails with a confusing error, and
---older Windows versions and some tools refuse the extended form too.
---@type table<string, true>
local DEVICE_NAMES = { con = true, prn = true, aux = true, nul = true }
for i = 1, 9 do
  DEVICE_NAMES["com" .. i] = true
  DEVICE_NAMES["lpt" .. i] = true
end

---Whether `name` is (or starts, before its first dot, like) a Windows device name.
---@param name any
---@return boolean
function M.is_reserved_name(name)
  if type(name) ~= "string" then
    return false
  end
  -- Windows also drops trailing spaces before the extension (`nul .txt`).
  local stem = name:match("^([^.]*)"):gsub("%s+$", "")
  return DEVICE_NAMES[stem:lower()] == true
end

---An area name becomes a path segment, so it is whitelisted (SEC-42): word
---characters, dots and hyphens, not starting with a dot or hyphen. A trailing
---dot is refused as well: Windows drops it, so `lib.nvim.` would silently be
---the folder `lib.nvim` under another id.
---@param name any
---@return boolean
function M.valid_area(name)
  return type(name) == "string"
    and name:match("^[%w_][%w_.-]*$") ~= nil
    and name ~= ".."
    and not name:find("..", 1, true)
    and name:sub(-1) ~= "."
end

---A slug is kebab-case ASCII: `a-z0-9` words joined by single hyphens.
---@param slug any
---@return boolean
function M.valid_slug(slug)
  return type(slug) == "string"
    and slug:match("^[a-z0-9][a-z0-9-]*$") ~= nil
    and not slug:find("--", 1, true)
    and slug:sub(-1) ~= "-"
end

---Lower-case letters with a diacritic -> ASCII. Anything else non-ASCII is dropped.
---@type table<string, string>
local FOLD = {
  ["ä"] = "ae",
  ["ö"] = "oe",
  ["ü"] = "ue",
  ["ß"] = "ss",
  ["à"] = "a",
  ["á"] = "a",
  ["â"] = "a",
  ["ã"] = "a",
  ["å"] = "a",
  ["æ"] = "ae",
  ["ç"] = "c",
  ["è"] = "e",
  ["é"] = "e",
  ["ê"] = "e",
  ["ë"] = "e",
  ["ì"] = "i",
  ["í"] = "i",
  ["î"] = "i",
  ["ï"] = "i",
  ["ñ"] = "n",
  ["ò"] = "o",
  ["ó"] = "o",
  ["ô"] = "o",
  ["õ"] = "o",
  ["ø"] = "o",
  ["œ"] = "oe",
  ["ù"] = "u",
  ["ú"] = "u",
  ["û"] = "u",
  ["ý"] = "y",
  ["ÿ"] = "y",
}

---`text` as kebab-case ASCII, with nothing put in for what is left: lower-cased, umlauts folded (`ü` -> `ue`), every
---other character a hyphen, runs of hyphens collapsed, no hyphen at either end. May be `""`. Not a string: `""`.
---@param text any
---@return string
function M.kebab(text)
  -- A NUL byte would make `vim.fn.tolower` raise ("Using a Blob as a String"); it becomes a hyphen like any other
  -- unusable character, so it is swapped for a space first.
  local lowered = vim.fn.tolower(((type(text) == "string" and text or ""):gsub("%z", " ")))
  local out = {}
  for ch in lowered:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if ch:match("^[a-z0-9]$") then
      out[#out + 1] = ch
    elseif FOLD[ch] then
      out[#out + 1] = FOLD[ch]
    else
      out[#out + 1] = "-"
    end
  end
  return (table.concat(out):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end

---The rule of `valid_slug`, in the words a message shows.
M.SLUG_RULE = "only a-z, 0-9 and single hyphens"

---Why `word` is no slug (`valid_slug`): the first fault, the character it is about (when one is) and a word that would
---do (`kebab`, absent when nothing usable is left). Nil when `word` is a slug.
---@param word any
---@return { reason: string, char?: string, suggestion?: string }|nil
function M.slug_problem(word)
  if M.valid_slug(word) then
    return nil
  end
  local text = type(word) == "string" and word or ""
  local problem
  if text == "" then
    problem = { reason = "an empty word is not allowed" }
  else
    -- one character at a time: a UTF-8 sequence whole, any other byte (a stray continuation byte) on its own
    local i = 1
    while i <= #text do
      local len = 1
      if text:byte(i) >= 194 and text:byte(i) <= 244 then
        local tail = text:match("^[\128-\191]+", i + 1)
        len = 1 + (tail and math.min(#tail, 3) or 0)
      end
      local ch = text:sub(i, i + len - 1)
      if not ch:match("^[a-z0-9-]$") then
        local shown = ch == " " and "a space" or ("'" .. M.printable(ch) .. "'")
        problem = { reason = shown .. " is not allowed", char = ch }
        break
      end
      i = i + len
    end
    if not problem then
      -- only a-z, 0-9 and hyphens left: the hyphens are wrong
      if text:sub(1, 1) == "-" then
        problem = { reason = "a hyphen at the start is not allowed", char = "-" }
      elseif text:find("--", 1, true) then
        problem = { reason = "a double hyphen is not allowed", char = "-" }
      else
        problem = { reason = "a hyphen at the end is not allowed", char = "-" }
      end
    end
  end
  local suggestion = M.kebab(text)
  problem.suggestion = M.valid_slug(suggestion) and suggestion or nil
  return problem
end

---A character as a message may show it: a control character (or a byte that is no UTF-8) as `\xNN`.
---@param ch string
---@return string
function M.printable(ch)
  if ch:match("^[%c\128-\255]$") or ch:match("^\194[\128-\159]$") then
    return (ch:gsub(".", function(b)
      return ("\\x%02X"):format(b:byte())
    end))
  end
  return ch
end

---The refusal of a word that must be a slug (a phase, an entry of `phase_order`), the same everywhere it is checked:
---`<label> '<word>': <reason> (<rule>); try '<suggestion>'`, and the details a front end shows (`field`, `value`,
---`char`, `suggestion`, the last two only when known). Nil when `word` is a slug.
---@param label string   # the field, e.g. `phase` or `phase_order`
---@param word any
---@return string|nil message
---@return { field: string, value: string, char?: string, suggestion?: string }|nil details
function M.slug_error(label, word)
  local problem = M.slug_problem(word)
  if not problem then
    return nil, nil
  end
  local text = type(word) == "string" and word or tostring(word == nil and "" or word)
  local shown = fsio.clean(text)
  local message = ("%s '%s': %s (%s)"):format(label, shown, problem.reason, M.SLUG_RULE)
  if problem.suggestion then
    message = message .. "; try '" .. problem.suggestion .. "'"
  end
  return message,
    { field = label, value = text, char = problem.char, suggestion = problem.suggestion }
end

---Split `<area>/<slug>`. A bare `<area>` gives `slug = nil`.
---@param id any
---@return string|nil area
---@return string|nil slug
---@return string|nil err
function M.parse_id(id)
  if type(id) ~= "string" or id == "" then
    return nil, nil, "empty task id"
  end
  local area, slug = id:match("^([^/]+)/([^/]+)$")
  if not area then
    if id:find("/", 1, true) then
      return nil, nil, "malformed task id (expected <area>/<slug>): " .. id
    end
    area = id
  end
  if not M.valid_area(area) then
    return nil, nil, "invalid area name: " .. area
  end
  if slug and not M.valid_slug(slug) then
    return nil, nil, "invalid slug: " .. slug
  end
  return area, slug, nil
end

---`<area>/ROADMAP/tasks`
---@param root string
---@param area string
---@return string
function M.tasks_dir(root, area)
  return root .. "/" .. area .. "/ROADMAP/tasks"
end

---`<area>/ROADMAP/plans`: the plan files of the area (optional).
---@param root string
---@param area string
---@return string
function M.plans_dir(root, area)
  return root .. "/" .. area .. "/ROADMAP/plans"
end

---`<area>/ROADMAP/plans/<slug>.md`
---@param root string
---@param area string
---@param slug string
---@return string
function M.plan_path(root, area, slug)
  return M.plans_dir(root, area) .. "/" .. slug .. ".md"
end

---`<area>/ROADMAP/projects`: the project files of the area (optional). A project groups plans (`project:` in a plan
---file) and may hold tasks of its own (`project:` in a task).
---@param root string
---@param area string
---@return string
function M.projects_dir(root, area)
  return root .. "/" .. area .. "/ROADMAP/projects"
end

---`<area>/ROADMAP/projects/<slug>.md`
---@param root string
---@param area string
---@param slug string
---@return string
function M.project_path(root, area, slug)
  return M.projects_dir(root, area) .. "/" .. slug .. ".md"
end

---The folder of a plan file (`kind` `plan`) or a project file (`project`), whichever form it has: `plans/<slug>.md`, or
---`plans/<slug>/<slug>.md` once something was attached to it (its assets lie in that folder).
---@param kind "plan"|"project"
---@return fun(root: string, area: string): string
local function dir_of(kind)
  return kind == "project" and M.projects_dir or M.plans_dir
end

---`<area>/ROADMAP/plans/<slug>/<slug>.md` (or `projects/`): a plan or project file that has a folder for its assets.
---@param root string
---@param kind "plan"|"project"
---@param area string
---@param slug string
---@return string
function M.plan_folder_path(root, kind, area, slug)
  return dir_of(kind)(root, area) .. "/" .. slug .. "/" .. slug .. ".md"
end

---Find an open plan file (`kind` `plan`) or project file (`project`) on disk, whichever form it has.
---@param root string
---@param kind "plan"|"project"
---@param area string
---@param slug string
---@return string|nil path
---@return boolean|string folder  # true for the folder form, false for a plain file; the error when there is none
function M.resolve_plan(root, kind, area, slug)
  local file = (kind == "project" and M.project_path or M.plan_path)(root, area, slug)
  local folder = M.plan_folder_path(root, kind, area, slug)
  local has_file, has_folder = fsio.is_file(file), fsio.is_file(folder)
  if has_file and has_folder then
    return nil, ("%s exists as file and as folder: %s/%s"):format(kind, area, slug)
  elseif has_file then
    return file, false
  elseif has_folder then
    return folder, true
  end
  return nil, ("no such open %s: %s/%s"):format(kind, area, slug)
end

---Whether an open plan file or project file of this slug is in the area, in either form (one id namespace).
---@param root string
---@param area string
---@param slug string
---@return boolean
function M.has_plan_or_project(root, area, slug)
  for _, kind in ipairs({ "plan", "project" }) do
    local file = (kind == "project" and M.project_path or M.plan_path)(root, area, slug)
    if fsio.is_file(file) or fsio.is_file(M.plan_folder_path(root, kind, area, slug)) then
      return true
    end
  end
  return false
end

---The plan or project files of one `ROADMAP/plans` (or `projects`) folder: `<slug>.md` and `<slug>/<slug>.md`.
---@param dir string
---@return { path: string, slug: string, folder: boolean }[]
function M.plan_files(dir)
  local out = {}
  if not fsio.is_dir(dir) then
    return out
  end
  for name, kind in vim.fs.dir(dir) do
    local slug = name:match("^(.+)%.md$")
    if kind == "file" and slug then
      out[#out + 1] = { path = dir .. "/" .. name, slug = slug, folder = false }
    elseif kind == "directory" and fsio.is_file(dir .. "/" .. name .. "/" .. name .. ".md") then
      out[#out + 1] =
        { path = dir .. "/" .. name .. "/" .. name .. ".md", slug = name, folder = true }
    end
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  return out
end

---`<area>/ROADMAP/TASKS.md`, the generated index.
---@param root string
---@param area string
---@return string
function M.index_path(root, area)
  return root .. "/" .. area .. "/ROADMAP/TASKS.md"
end

---`<area>/Backlog/<bucket>`
---@param root string
---@param area string
---@param bucket Tasks.Bucket
---@return string
function M.backlog_dir(root, area, bucket)
  return root .. "/" .. area .. "/Backlog/" .. bucket
end

---`<area>/Backlog/README.md`
---@param root string
---@param area string
---@return string
function M.backlog_readme(root, area)
  return root .. "/" .. area .. "/Backlog/README.md"
end

---`<area>/ROADMAP/tasks/<slug>.md`
---@param root string
---@param area string
---@param slug string
---@return string
function M.task_path(root, area, slug)
  return M.tasks_dir(root, area) .. "/" .. slug .. ".md"
end

---`<area>/ROADMAP/tasks/<slug>`, the folder of a folder task.
---@param root string
---@param area string
---@param slug string
---@return string
function M.task_dir(root, area, slug)
  return M.tasks_dir(root, area) .. "/" .. slug
end

---`<area>/ROADMAP/tasks/<slug>/<slug>.md`, the task file of a folder task.
---@param root string
---@param area string
---@param slug string
---@return string
function M.folder_task_path(root, area, slug)
  return M.task_dir(root, area, slug) .. "/" .. slug .. ".md"
end

---Find an open task on disk, whichever form it has.
---@param root string
---@param area string
---@param slug string
---@return string|nil path   the task file
---@return boolean|string folder  true for a folder task; the error text when `path` is nil
function M.resolve_task(root, area, slug)
  local file, folder = M.task_path(root, area, slug), M.folder_task_path(root, area, slug)
  local has_file, has_folder = fsio.is_file(file), fsio.is_file(folder)
  if has_file and has_folder then
    return nil, ("task exists as file and as folder: %s/%s"):format(area, slug)
  elseif has_file then
    return file, false
  elseif has_folder then
    return folder, true
  end
  return nil, "no such open task: " .. area .. "/" .. slug
end

---Why `dir` must not be read as part of the vault, or nil: a symbolic link or a junction on the way (`<area>`,
---`ROADMAP`, `tasks`, ...) leads out of `root`. Both are resolved on disk first, so a link that stays inside the vault
---and a vault that itself sits below a link (`/var` on macOS) are fine.
---@param root string
---@param dir string
---@return string|nil err
function M.leaves(root, dir)
  local real_dir, real_root = fsio.realpath(dir), fsio.realpath(root)
  if real_dir and real_root and not fsio.is_inside(real_root, real_dir) then
    local shown = fsio.norm(dir)
    local base = fsio.norm(root)
    if fsio.is_inside(base, shown) then
      shown = shown:sub(#base + 2)
    end
    return ("%s leaves the vault (a symbolic link or junction): not read"):format(shown)
  end
  return nil
end

---Whether the folder `<root>/<name>` is an area: it holds `ROADMAP/` or
---`Backlog/`, or is one of `EXTRA_AREAS`; hidden and `_`-prefixed folders and
---`SKIP` entries never are.
---@param root string
---@param name string
---@return boolean
local function is_area_dir(root, name)
  if not M.valid_area(name) or name:match("^[._]") or M.SKIP[name] then
    return false
  end
  local dir = root .. "/" .. name
  -- A link (a symbolic link, a junction) is a way out of the vault: what it points at is not the vault's.
  if not fsio.is_dir(dir) or fsio.is_link(dir) then
    return false
  end
  for _, extra in ipairs(M.extra_areas(root)) do
    if extra == name then
      return true
    end
  end
  return fsio.is_dir(dir .. "/ROADMAP") or fsio.is_dir(dir .. "/Backlog")
end

---Every area, sorted by name (see `is_area_dir` for what counts).
---@param root string
---@return Tasks.Area[]
function M.areas(root)
  -- The list is the same for every question of one read scope; a copy is handed out (callers may sort or edit it).
  local shared = fsio.scope_memo("areas:" .. root, function()
    return M.scan_areas(root)
  end)
  local out = {}
  for i, a in ipairs(shared) do
    out[i] = { name = a.name, path = a.path }
  end
  return out
end

---The areas as the disk has them now (`M.areas` without the read scope's memory).
---@param root string
---@return Tasks.Area[]
function M.scan_areas(root)
  local out = {}
  local handle = uv.fs_scandir(root)
  if not handle then
    return out
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if is_area_dir(root, name) then
      out[#out + 1] = { name = name, path = root .. "/" .. name }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

---The names of `M.areas(root)`.
---@param root string
---@return string[]
function M.area_names(root)
  return vim.tbl_map(function(a)
    return a.name
  end, M.areas(root))
end

---Whether `root` holds an entry named exactly `name`. A path lookup is not
---that strict: on Windows (and macOS) `stat` finds `LIB.NVIM` and `lib.nvim.`
---for the folder `lib.nvim`, so an id typed in the wrong case would write into
---the right folder under a different id.
---@param root string
---@param name string
---@return boolean
function M.dir_listed(root, name)
  local handle = uv.fs_scandir(root)
  if not handle then
    return false
  end
  while true do
    local entry = uv.fs_scandir_next(handle)
    if not entry then
      return false
    end
    if entry == name then
      return true
    end
  end
end

---Whether `area` is one of the vault's areas. The name must match the folder's spelling
---exactly: an area in another case would reach the same folder on Windows, yet become a second
---id for the same tasks, and its generated index would read as stale (`index-stale`).
---@param root string
---@param area string
---@return boolean
function M.has_area(root, area)
  return type(area) == "string" and is_area_dir(root, area) and M.dir_listed(root, area)
end

---The areas of `names` that come close to a name that is none: those that start with it first, then those that
---only contain it (any case), three at most. The name has to be the folder's (`hover.nvim`, not `hover`).
---@param area string
---@param names string[]
---@return string[]
function M.close_areas(area, names)
  local starts, within = {}, {}
  local needle = area:lower()
  for _, name in ipairs(names) do
    local at = name:lower():find(needle, 1, true)
    if at == 1 then
      starts[#starts + 1] = name
    elseif at then
      within[#within + 1] = name
    end
  end
  return vim.list_slice(vim.list_extend(starts, within), 1, 3)
end

---The report for a name that is no area of the vault, with the areas that come close.
---@param area string
---@param names string[] the areas of the vault
---@return string
function M.not_an_area_message(area, names)
  local close = M.close_areas(area, names)
  local hint = #close > 0 and (" (did you mean: %s?)"):format(table.concat(close, ", ")) or ""
  return ("'%s' is not an area of the vault%s"):format(area, hint)
end

---What a name a filter takes (`list`, `next`, `plans`, the dashboard) stands for: an area, which wins, or an
---area group's members (`tasks_nvim.area_groups`). A write (`new`, a move) keeps asking `has_area`.
---@param root string
---@param name string
---@return Tasks.AreaScope|nil scope
---@return string|nil err
function M.area_scope(root, name)
  return require("tasks_nvim.area_groups").resolve(root, name)
end

return M
