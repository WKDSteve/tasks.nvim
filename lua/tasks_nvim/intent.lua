---@module 'tasks_nvim.intent'
---@brief Taking an intent `wkd-intent/1` (`appkit/schemas/wkd-intent/1`): what one app hands to tasks.nvim.
---@description
--- An intent is what another app (testing.nvim, the hub) hands over: "create a task from this finding", "show this task".
--- It has fixed actions and writes nothing by itself. tasks takes two of them, `tasks.new` and `tasks.show`, in mode `form`
--- (what a person confirms: the headless engine answers what it WOULD create, `--yes` creates it).
---
--- An intent is untrusted input, wherever it came from (README of the schema, "What the target checks"):
---  1. more than 64 KiB, measured before it is parsed;
---  2. not one JSON object of this schema (a higher version, a missing field, a mode the action does not allow);
---  3. an action tasks did not offer in the handshake (`hello.intents`);
---  4. a `class` other than `public` or `internal`;
---  5. an absolute path or a way out of the repository in `finding.where.file`, `finding.repro` or `target.id`;
---  6. lengths (title 120, excerpt 4096, repro 1000, file and id 300) and control characters in any field;
---  7. a `finding.run.url` that does not start with `https://github.com/`.
--- `check` names every problem, nothing is written when there is one. The Lua is a port of `tools/check-wkd-intent.py`
--- of appkit, the reference; `TESTS/intent/` holds copies of its golden examples.
---
--- A task made from a finding carries the ref `testing-finding:<fp>`: the same finding twice is `exists`, never a second task.
---
--- Not its job: the form of the editor (`:Tasks new` filled in), the transport (clipboard, hub route).

local M = {}

M.SCHEMA = "wkd-intent/1"
M.MAX_BYTES = 64 * 1024

---Every action of the schema, and the ones tasks takes.
M.ACTIONS = { "tasks.new", "tasks.show", "rules.show", "rules.new", "ai.handoff" }
M.OFFERED = { "tasks.new", "tasks.show" }
---Every mode of the schema, and the ones tasks takes (a headless engine has no `ai-draft` or `agent` of its own).
M.MODES = { "form", "ai-draft", "agent" }
M.OFFERED_MODES = { "form" }

local SHOW = { ["tasks.show"] = true, ["rules.show"] = true }
local CLASSES = { public = true, internal = true }
local LIMITS = { title = 120, excerpt = 4096, repro = 1000 }
local MAX_PATH = 300
local RUN_URL = "https://github.com/"

---The ref a task made from a finding carries: `testing-finding:<fp>`.
M.FINDING_NAMESPACE = "testing-finding"

---@param action any
---@param set string[]
---@return boolean
local function in_list(action, set)
  for _, v in ipairs(set) do
    if v == action then
      return true
    end
  end
  return false
end

---What tasks says in its handshake (`call hello`): the actions and modes it takes.
---@return { schema: string, actions: string[], modes: string[] }
function M.handshake()
  return {
    schema = M.SCHEMA,
    actions = vim.list_slice(M.OFFERED, 1),
    modes = vim.list_slice(M.OFFERED_MODES, 1),
  }
end

---A control character other than tab, line feed and carriage return, or one of the C1 block (as UTF-8).
---@param s string
---@return boolean
local function has_control(s)
  return s:find("[%z\1-\8\11\12\14-\31\127]") ~= nil or s:find("\194[\128-\159]") ~= nil
end

---@param c string  # one byte
---@return boolean
local function is_space(c)
  return c:match("%s") ~= nil
end

---Does a word of `text` leave the repository: an absolute path, a home, a drive, a variable, a `..` segment. Quotes and
---`=` start a word too (`--out="/etc/x"`, `--out=/etc/x`). The port of `ESCAPE` of the reference.
---@param text string
---@return boolean
local function leaves_repo(text)
  local n = #text
  for i = 1, n + 1 do
    local before = i > 1 and text:sub(i - 1, i - 1) or nil
    local word_start = before == nil
      or is_space(before)
      or before == '"'
      or before == "'"
      or before == "="
    if word_start and i <= n then
      local c = text:sub(i, i)
      local two = text:sub(i, i + 1)
      if c == "/" or c == "\\" then
        return true
      end
      if text:sub(i):match("^%a:[/\\]") then
        return true
      end
      if two == "~/" or two == "~\\" then
        return true
      end
      local home = text:sub(i):match("^%$(%{?HOME)")
      if home then
        local after = text:sub(i + 1 + #home, i + 1 + #home)
        if after == "" or not after:match("[%w_]") then
          return true
        end
      end
      local var = text:sub(i):match("^%%(%a+)%%")
      if var then
        return true
      end
    end
    -- `..` after the start of a word, a quote, `=`, a space or a slash, and followed by a slash, a space or the end
    local dotted = before == nil
      or is_space(before)
      or before == '"'
      or before == "'"
      or before == "="
      or before == "/"
      or before == "\\"
    if dotted and text:sub(i, i + 1) == ".." then
      local after = text:sub(i + 2, i + 2)
      if after == "" or after == "/" or after == "\\" or is_space(after) then
        return true
      end
    end
  end
  return false
end

M.leaves_repo = leaves_repo

---Every string of a decoded document (keys and values), without recursion deeper than the stack.
---@param value any
---@return fun(): string|nil
local function strings_of(value)
  local stack = { value }
  return function()
    while #stack > 0 do
      local item = table.remove(stack)
      if type(item) == "string" then
        return item
      elseif type(item) == "table" then
        for k, v in pairs(item) do
          stack[#stack + 1] = k
          stack[#stack + 1] = v
        end
      end
    end
    return nil
  end
end

---@param text string
---@return integer
local function chars(text)
  return vim.fn.strchars(text)
end

---@param finding table
---@param out string[]
local function check_finding(finding, out)
  if finding.schema ~= "testing-finding/1" then
    out[#out + 1] = "finding.schema is not testing-finding/1"
  end
  if
    not (
      type(finding.fp) == "string"
      and finding.fp:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$")
      and not finding.fp:match("%u")
    )
  then
    out[#out + 1] = "finding.fp is not 16 hex characters"
  end
  if type(finding.class) ~= "string" or not CLASSES[finding.class] then
    out[#out + 1] = "finding.class is not public or internal"
  end
  if not (type(finding.title) == "string" and finding.title ~= "") then
    out[#out + 1] = "finding.title is missing"
  end
  if type(finding.excerpt) ~= "string" then
    out[#out + 1] = "finding.excerpt is missing"
  end
  for _, key in ipairs({ "title", "excerpt", "repro" }) do
    local text = finding[key]
    if type(text) == "string" and chars(text) > LIMITS[key] then
      out[#out + 1] = ("finding.%s is longer than %d"):format(key, LIMITS[key])
    end
  end
  local repro = finding.repro
  if repro ~= nil and repro ~= vim.NIL and type(repro) ~= "string" then
    out[#out + 1] = "finding.repro is not a string"
  elseif type(repro) == "string" and leaves_repo(repro) then
    out[#out + 1] = "finding.repro leaves the repository"
  end
  local where = finding.where
  if where ~= nil and where ~= vim.NIL then
    local file = type(where) == "table" and where.file or nil
    if type(file) ~= "string" then
      out[#out + 1] = "finding.where.file is missing"
    elseif chars(file) > MAX_PATH then
      out[#out + 1] = ("finding.where.file is longer than %d"):format(MAX_PATH)
    elseif leaves_repo(file) then
      out[#out + 1] = "finding.where.file leaves the repository"
    end
  end
  local run = finding.run
  local url = type(run) == "table" and run.url or nil
  if
    url ~= nil
    and url ~= vim.NIL
    and not (type(url) == "string" and url:sub(1, #RUN_URL) == RUN_URL)
  then
    out[#out + 1] = "finding.run.url does not start with " .. RUN_URL
  end
end

---Every reason to refuse an intent; empty when tasks may take it. Never throws on any input.
---@param input string|table  the JSON text (the size is measured before it is parsed) or a decoded document
---@return string[] problems
---@return table|nil doc  the decoded document when it is one
function M.check(input)
  local doc = input
  if type(input) == "string" then
    if #input > M.MAX_BYTES then
      return { ("larger than %d bytes"):format(M.MAX_BYTES) }, nil
    end
    local ok, decoded =
      pcall(vim.json.decode, input, { luanil = { object = false, array = false } })
    if not ok then
      return { "not JSON in UTF-8" }, nil
    end
    doc = decoded
  else
    local ok, encoded = pcall(vim.json.encode, input)
    if not ok then
      return { "not JSON in UTF-8" }, nil
    end
    if #encoded > M.MAX_BYTES then
      return { ("larger than %d bytes"):format(M.MAX_BYTES) }, nil
    end
  end
  if type(doc) ~= "table" or (doc[1] ~= nil) then
    return { "not a JSON object" }, nil
  end
  if doc.schema ~= M.SCHEMA then
    return { ("schema %s is not %s"):format(vim.inspect(doc.schema), M.SCHEMA) }, nil
  end
  local out = {}
  local action, mode = doc.action, doc.mode
  if not in_list(action, M.ACTIONS) then
    out[#out + 1] = "unknown action"
  elseif not in_list(action, M.OFFERED) then
    out[#out + 1] = ("this target does not take %s"):format(action)
  end
  if not in_list(mode, M.MODES) then
    out[#out + 1] = "unknown mode"
  elseif SHOW[action] and mode ~= "form" then
    out[#out + 1] = ("%s only knows mode form"):format(action)
  elseif not in_list(mode, M.OFFERED_MODES) then
    out[#out + 1] = ("this target does not take mode %s (it takes %s)"):format(
      mode,
      table.concat(M.OFFERED_MODES, ", ")
    )
  end
  local source = doc.source
  local app = type(source) == "table" and source.app or nil
  if not (type(app) == "string" and app:match("^%l[%l%d-]*$") and #app <= 64) then
    out[#out + 1] = "source.app is missing or not a plain name"
  end
  -- a document that arrives as text must name `finding` and `target` (null is a value); one that arrives decoded may have
  -- lost its nulls on the way (the API door drops them), so an absent key counts as null there
  if type(input) == "string" then
    for _, key in ipairs({ "finding", "target" }) do
      if doc[key] == nil then
        out[#out + 1] = key .. " is missing"
      end
    end
  end
  local finding, target = doc.finding, doc.target
  if finding == vim.NIL then
    finding = nil
  end
  if target == vim.NIL then
    target = nil
  end
  if SHOW[action] then
    if finding ~= nil then
      out[#out + 1] = action .. " carries no finding"
    end
    local tid = type(target) == "table" and target.id or nil
    if not (type(tid) == "string" and tid ~= "") then
      out[#out + 1] = "target.id is missing"
    elseif chars(tid) > MAX_PATH then
      out[#out + 1] = ("target.id is longer than %d"):format(MAX_PATH)
    elseif leaves_repo(tid) then
      out[#out + 1] = "target.id leaves the repository"
    end
  elseif in_list(action, M.ACTIONS) then
    if target ~= nil then
      out[#out + 1] = action .. " has no target"
    end
    if type(finding) == "table" then
      check_finding(finding, out)
    else
      out[#out + 1] = action .. " needs a finding"
    end
  end
  for text in strings_of(doc) do
    if has_control(text) then
      out[#out + 1] = "a field holds a control character"
      break
    end
  end
  return out, doc
end

-- ── what taking an intent does ───────────────────────────────────────────────

---@param finding table
---@return string
function M.finding_ref(finding)
  return M.FINDING_NAMESPACE .. ":" .. finding.fp
end

---The first line of a text, cut to `max` characters.
---@param text string
---@param max integer
---@return string
local function first_line(text, max)
  local line = vim.trim((text:match("^[^\r\n]*")) or "")
  if chars(line) > max then
    line = vim.fn.strcharpart(line, 0, max - 1) .. "\226\128\166"
  end
  return line
end

---The refs of the task a finding becomes: the dedupe key, the place in the repo (`file:line`) and `repo@sha`.
---@param finding table
---@return string[]
function M.refs_of(finding)
  local refs = { M.finding_ref(finding) }
  local where = type(finding.where) == "table" and finding.where or nil
  if where and type(where.file) == "string" and where.file ~= "" then
    local ref = where.file
    if
      type(where.line) == "number"
      and where.line >= 1
      and where.line == math.floor(where.line)
    then
      ref = ref .. ":" .. tostring(where.line)
    end
    refs[#refs + 1] = ref
  end
  if
    type(finding.repo) == "string"
    and finding.repo:match("^[%w._-]+$")
    and type(finding.sha) == "string"
    and finding.sha:match("^%x+$")
    and #finding.sha >= 7
    and #finding.sha <= 40
  then
    refs[#refs + 1] = finding.repo .. "@" .. finding.sha
  end
  return refs
end

---The body of the task a finding becomes (German headings, as a new task without `--lang`).
---@param finding table
---@param lang "de"|"en"
---@return string
function M.body_of(finding, lang)
  local en = lang == "en"
  local lines = {
    "",
    first_line(finding.excerpt or "", 300),
    "",
    en and "## Context" or "## Kontext",
    "",
    en and "A finding of testing.nvim (`" .. finding.fp .. "`):"
      or "Ein Befund von testing.nvim (`" .. finding.fp .. "`):",
    "",
    "```",
    (finding.excerpt or ""):gsub("```", "'''"),
    "```",
  }
  if type(finding.repro) == "string" and finding.repro ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = (en and "Reproduce: `" or "Nachstellen: `")
      .. finding.repro:gsub("`", "'")
      .. "`"
  end
  local run = type(finding.run) == "table" and finding.run or nil
  if run and type(run.url) == "string" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = (en and "Run: " or "Lauf: ") .. run.url
  end
  vim.list_extend(lines, {
    "",
    en and "## Acceptance" or "## Akzeptanz",
    "",
    en and "- [ ] the finding is gone (its test is green)"
      or "- [ ] der Befund ist behoben (der Test ist grün)",
    "",
    en and "## Notes" or "## Notizen",
    "",
  })
  return table.concat(lines, "\n")
end

---@class Tasks.IntentResult
---@field action string
---@field outcome "would_create"|"created"|"exists"|"shown"|"not_found"
---@field id? string                 # the task (created, or the one that exists, or the one shown)
---@field area? string
---@field title? string
---@field status? string
---@field location? "open"|"done"
---@field matches? { id: string, area: string, status: string, location: string }[]  # `exists`: the tasks that hold the ref

---Take an intent: check it, then answer what it would do or (with `opts.yes`) do it.
---@param input string|table
---@param opts? { root?: string, today?: string, yes?: boolean, lang?: "de"|"en" }
---@return Tasks.IntentResult|nil result
---@return string|nil err  # every problem, one line
function M.run(input, opts)
  opts = opts or {}
  local problems, doc = M.check(input)
  if #problems > 0 then
    return nil, "intent refused: " .. table.concat(problems, "; ")
  end
  ---@cast doc table
  local vault = require("tasks_nvim.vault")
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local finder = require("tasks_nvim.find")

  if doc.action == "tasks.show" then
    local id = doc.target.id
    local area, slug, perr = vault.parse_id(id)
    if not area or not slug then
      return nil, "intent refused: target.id: " .. tostring(perr)
    end
    local found = finder.by_id(id, { root = root })
    if not found then
      return { action = doc.action, outcome = "not_found", id = id }, nil
    end
    return {
      action = doc.action,
      outcome = "shown",
      id = found.id,
      area = found.area,
      status = found.status,
      location = found.location,
      title = found.title,
    },
      nil
  end

  -- tasks.new
  local finding = doc.finding
  local area = finding.area
  if type(area) ~= "string" or not vault.valid_area(area) or not vault.has_area(root, area) then
    return nil,
      ("intent refused: finding.area '%s' is no area of this vault"):format(tostring(area))
  end
  local ref = M.finding_ref(finding)
  local matches = finder.by_refs({ ref }, { root = root })
  if #matches > 0 then
    local first = matches[1]
    return {
      action = doc.action,
      outcome = "exists",
      id = first.id,
      area = first.area,
      status = first.status,
      location = first.location,
      matches = matches,
    },
      nil
  end
  local proposal = { action = doc.action, area = area, title = finding.title }
  if not opts.yes then
    proposal.outcome = "would_create"
    return proposal, nil
  end
  local made, err = require("tasks_nvim.mutate").new(area, {
    root = root,
    today = opts.today,
    title = finding.title,
    kind = "bug",
    tags = { "testing" },
    refs = M.refs_of(finding),
    summary = first_line(finding.excerpt or "", 300),
    body = M.body_of(finding, opts.lang or "de"),
    lang = opts.lang,
  })
  if not made then
    return nil, tostring(err)
  end
  proposal.outcome = "created"
  proposal.id = made.id
  return proposal, nil
end

return M
