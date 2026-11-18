---@module 'tasks_nvim.review'
---@brief The review of a finished task by ai-desktop (`kind=review-done`): the block of its answer, and adding it to the
---task as a section after a yes.
---@description
--- ai-desktop's review agent only reads; its answer ends with one block between `<!-- review:begin -->` and
--- `<!-- review:end -->`: a section `## Prüfung` (or `## Review`), one line per acceptance criterion, and, when something
--- is open, `### Folgetask (Vorschlag)` / `### Follow-up task (proposal)` with `- title:` and `- summary:`. This module
--- finds the block (`block`), the proposed follow-up (`follow_up`) and writes the section into the task file
--- (`adopt`): the open file or the finished one in `Backlog/`, replacing a section of the same name, under the file
--- lock of the engine. It never decides on its own: `:Tasks agent` asks the person first (`tasks_nvim.ui.cmd`).
---
--- A prepared decision (`kind=prepare-decision`) is the same kind of answer with the markers `<!-- decision:begin -->`
--- / `<!-- decision:end -->` and two sections: `## Vorschlag` (`## Proposal`: options, consequences, the
--- recommendation, open assumptions) and `## Offene Fragen` (`## Open questions`, the format of `tasks_nvim.questions`,
--- which `answer` answers). `check_decision` takes it apart and checks it, `with_decision` puts it into the text of a
--- task: the proposal replaces an earlier one, the questions go in only when the task has none of its own (those are
--- the person's and stay).
--- Low-level: no notification here.

local M = {}

M.BEGIN = "<!-- review:begin -->"
M.END = "<!-- review:end -->"
M.DECISION_BEGIN = "<!-- decision:begin -->"
M.DECISION_END = "<!-- decision:end -->"
M.SPLIT_BEGIN = "<!-- split:begin -->"
M.SPLIT_END = "<!-- split:end -->"

-- More drafts than this are no split of one plan.
M.MAX_DRAFTS = 30

local PROPOSAL_HEADINGS = { "## Vorschlag", "## Proposal" }
local QUESTION_HEADINGS = { "## Offene Fragen", "## Open questions" }

-- A section heading the block may start with; another heading is refused (the block is foreign text).
local HEADINGS = { "## Prüfung", "## Review" }
-- More than this is no review of one task.
local MAX_BLOCK = 32 * 1024

---The last block of an answer (without the markers, trimmed), or nil: a review's, or with `which = "decision"` a
---prepared decision's.
---@param output string
---@param which? "review"|"decision"|"split"
---@return string|nil
function M.block(output, which)
  local begin_mark = which == "decision" and M.DECISION_BEGIN
    or which == "split" and M.SPLIT_BEGIN
    or M.BEGIN
  local end_mark = which == "decision" and M.DECISION_END
    or which == "split" and M.SPLIT_END
    or M.END
  local found
  local from = 1
  while true do
    local b = output:find(begin_mark, from, true)
    if not b then
      break
    end
    local e = output:find(end_mark, b + #begin_mark, true)
    if not e then
      break
    end
    found = output:sub(b + #begin_mark, e - 1)
    from = e + #end_mark
  end
  if not found then
    return nil
  end
  found = vim.trim((found:gsub("\r\n", "\n")))
  return found ~= "" and found or nil
end

---Whether the block is one this module adds: it starts with one of the headings and is of a sane size.
---@param block string
---@return boolean ok
---@return string|nil why
function M.check(block)
  if #block > MAX_BLOCK then
    return false, ("the review is larger than %d KiB"):format(MAX_BLOCK / 1024)
  end
  -- Foreign text that goes into a task file: no control character but tab and line end (a model's answer reaches
  -- here uncleaned when ai-desktop asked a model once), and no second section of the task's level, which would take
  -- the place of the task's own sections (and stay behind when the next review replaces this one).
  if block:find("[%z\1-\8\11\12\14-\31\127]") then
    return false, "the review holds a control character"
  end
  local first = block:match("^[^\n]*")
  if block:sub(#first + 1):find("\n## ") then
    return false, "the review holds a second section (## ...); only ### headings may follow its own"
  end
  for _, heading in ipairs(HEADINGS) do
    if first == heading then
      return true, nil
    end
  end
  return false, "the review does not start with ## Prüfung or ## Review"
end

---The `## ` sections of a block, in order: `{ heading, text }` (the text starts with its heading line).
---@param block string
---@return { heading: string, text: string }[]
local function sections(block)
  local out = {}
  for line in (block .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^## ") then
      out[#out + 1] = { heading = line, lines = { line } }
    elseif #out > 0 then
      table.insert(out[#out].lines, line)
    end
  end
  for _, sec in ipairs(out) do
    sec.text = vim.trim(table.concat(sec.lines, "\n"))
    sec.lines = nil
  end
  return out
end

---Takes a prepared decision apart and checks it: the proposal (`## Vorschlag` / `## Proposal`, first) and, when
---there, the questions (`## Offene Fragen` / `## Open questions`), nothing else of the task's level, no control
---character, at most 32 KiB. The questions must read as questions of `tasks_nvim.questions`: at least one, each with
---two options or more, none answered, no problem `check` would report.
---@param block string
---@return { proposal: string, questions: string|nil }|nil parts
---@return string|nil why
function M.check_decision(block)
  if #block > MAX_BLOCK then
    return nil, ("the proposal is larger than %d KiB"):format(MAX_BLOCK / 1024)
  end
  if block:find("[%z\1-\8\11\12\14-\31\127]") then
    return nil, "the proposal holds a control character"
  end
  local secs = sections(block)
  if #secs == 0 or not block:match("^## ") then
    return nil, "the proposal does not start with ## Vorschlag or ## Proposal"
  end
  if not vim.tbl_contains(PROPOSAL_HEADINGS, secs[1].heading) then
    return nil, "the proposal does not start with ## Vorschlag or ## Proposal"
  end
  local parts = { proposal = secs[1].text }
  if secs[2] then
    if not vim.tbl_contains(QUESTION_HEADINGS, secs[2].heading) or secs[3] then
      return nil, "the proposal holds a section that is neither ## Vorschlag nor ## Offene Fragen"
    end
    local parsed = require("tasks_nvim.questions").parse(secs[2].text .. "\n")
    if not parsed then
      return nil, "its open questions hold no question (### ...? [qN] with options)"
    end
    if #parsed.problems > 0 then
      return nil, "its open questions: " .. parsed.problems[1]
    end
    for _, q in ipairs(parsed.items) do
      if #q.options < 2 then
        return nil, ("its question %q has fewer than two options"):format(q.title)
      end
      if q.answered then
        return nil, ("its question %q is answered already; the person decides"):format(q.title)
      end
    end
    parts.questions = secs[2].text
  end
  return parts, nil
end

---The text of a task with a prepared decision: the proposal as its section (replacing an earlier one of the same
---heading), the questions only when the task has no questions of its own. `added` says whether they went in.
---@param text string
---@param parts { proposal: string, questions: string|nil }
---@return string new_text
---@return boolean added
function M.with_decision(text, parts)
  local out = M.with_section(text, parts.proposal)
  local added = false
  if parts.questions and not require("tasks_nvim.questions").parse(text) then
    out = M.with_section(out, parts.questions)
    added = true
  end
  return out, added
end

---@class Tasks.SplitDraft
---@field n integer               # Its position in the list, from 1 (`#n` in another draft's after/blocked_by).
---@field title string
---@field area string
---@field kind? string
---@field prio? integer
---@field effort? string
---@field value? integer
---@field phase? string
---@field summary? string
---@field acceptance string[]
---@field after string[]
---@field blocked_by string[]
---@field invalid? string          # Why it cannot be created as it is (its form); the engine checks the values later.

---One string of a draft: nil when missing, false and why when it is not one line of text.
---@param value any
---@param what string
---@return string|nil|false
---@return string|nil
local function one_line(value, what)
  if value == nil then
    return nil
  end
  if type(value) ~= "string" then
    return false, what .. " is not text"
  end
  if value:find("[%z\1-\31\127]") then
    return false, what .. " is not one line of text"
  end
  return vim.trim(value)
end

---A list of one-line strings of a draft (missing: empty).
---@param value any
---@param what string
---@return string[]|false
---@return string|nil
local function line_list(value, what)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" or not vim.islist(value) then
    return false, what .. " is not a list"
  end
  local out = {}
  for _, item in ipairs(value) do
    local text, why = one_line(item, what)
    if not text then
      return false, why or (what .. " holds an empty entry")
    end
    if text ~= "" then
      out[#out + 1] = text
    end
  end
  return out
end

---The phases and drafts of a split (`kind=split-plan`): the JSON object of the block. Nil and why when the block is
---not such an object or names no draft; a draft whose form is wrong is kept with `invalid` (shown, never created).
---The values (kind, prio, area ...) are the engine's to check when a draft is created.
---@param block string
---@return { phases: { name: string, new: boolean }[], drafts: Tasks.SplitDraft[] }|nil
---@return string|nil why
function M.parse_split(block)
  if #block > MAX_BLOCK * 2 then
    return nil, ("the drafts are larger than %d KiB"):format(MAX_BLOCK * 2 / 1024)
  end
  local json = vim.trim((block:gsub("^```%w*", ""):gsub("```%s*$", "")))
  local good, doc = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
  if not good or type(doc) ~= "table" or vim.islist(doc) then
    return nil, "the drafts are not one JSON object"
  end
  if type(doc.tasks) ~= "table" or not vim.islist(doc.tasks) or #doc.tasks == 0 then
    return nil, "the split proposes no task"
  end
  if #doc.tasks > M.MAX_DRAFTS then
    return nil, ("the split proposes %d tasks, more than %d"):format(#doc.tasks, M.MAX_DRAFTS)
  end
  local phases = {}
  for _, p in ipairs(type(doc.phases) == "table" and vim.islist(doc.phases) and doc.phases or {}) do
    local name = type(p) == "table" and one_line(p.name, "phase") or nil
    if name and name ~= "" then
      phases[#phases + 1] = { name = name, new = p.new == true }
    end
  end
  local drafts = {}
  for n, t in ipairs(doc.tasks) do
    local d = { n = n, acceptance = {}, after = {}, blocked_by = {} }
    local function bad(why)
      d.invalid = d.invalid or why
    end
    if type(t) ~= "table" or vim.islist(t) then
      d.title = "(not a draft)"
      d.area = ""
      bad("not an object")
    else
      for _, key in ipairs({ "title", "area", "kind", "effort", "phase", "summary" }) do
        local text, why = one_line(t[key], key)
        if text == false then
          bad(why)
        elseif text ~= nil then
          d[key] = text
        end
      end
      for _, key in ipairs({ "prio", "value" }) do
        if t[key] ~= nil then
          if type(t[key]) ~= "number" or t[key] ~= math.floor(t[key]) then
            bad(key .. " is not a whole number")
          else
            d[key] = t[key]
          end
        end
      end
      for _, key in ipairs({ "acceptance", "after", "blocked_by" }) do
        local list, why = line_list(t[key], key)
        if list == false then
          bad(why)
        else
          d[key] = list
        end
      end
      if not d.title or d.title == "" then
        d.title = d.title or "(no title)"
        bad("it has no title")
      end
      if not d.area or d.area == "" then
        d.area = d.area or ""
        bad("it names no area")
      end
    end
    drafts[n] = d
  end
  return { phases = phases, drafts = drafts }, nil
end

---The follow-up task the review proposes (`title`, `summary`), or nil when it proposes none.
---@param block string
---@return { title: string, summary: string|nil }|nil
function M.follow_up(block)
  local in_section = false
  local found = {}
  for line in (block .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^###%s+Folgetask") or line:match("^###%s+Follow%-up") then
      in_section = true
    elseif line:match("^#") then
      in_section = false
    elseif in_section then
      local key, value = line:match("^%-%s*(%a+):%s*(.-)%s*$")
      if key and value ~= "" and (key == "title" or key == "summary") then
        found[key] = value
      end
    end
  end
  if not found.title then
    return nil
  end
  return { title = found.title, summary = found.summary }
end

---The text with `block` as its section: a section of the same heading (to the next `## ` heading or the end) is
---replaced, else the block is added at the end.
---@param text string
---@param block string
---@return string
function M.with_section(text, block)
  local heading = block:match("^[^\n]*")
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  local first, after
  for i, line in ipairs(lines) do
    if not first then
      if line == heading then
        first = i
      end
    elseif line:match("^## ") then
      after = i
      break
    end
  end
  local new = vim.split(block, "\n", { plain = true })
  local out
  if first then
    out = vim.list_slice(lines, 1, first - 1)
    vim.list_extend(out, new)
    if after then
      out[#out + 1] = ""
      vim.list_extend(out, vim.list_slice(lines, after))
    end
  else
    out = lines
    out[#out + 1] = ""
    vim.list_extend(out, new)
  end
  return table.concat(out, "\n") .. "\n"
end

---Writes the review into the task file at `path` (open or finished) under the engine's file lock, through a
---temporary file; `updated` becomes `today`. A link is not written through.
---@param path string
---@param block string
---@param today string YYYY-MM-DD
---@return boolean ok
---@return string|nil err
function M.adopt(path, block, today)
  local fsio = require("tasks_nvim.fsio")
  local good, why = M.check(block)
  if not good then
    return false, why
  end
  if fsio.is_link(path) then
    return false, path .. " is a symbolic link or junction: it is not written through"
  end
  local ok, err = fsio.with_lock(path, function()
    local text, rerr = fsio.read(path)
    if not text then
      return nil, "cannot read " .. path .. ": " .. tostring(rerr)
    end
    local new_text = M.with_section(text, block)
    local stamped, uerr =
      require("lib.nvim.markdown.frontmatter").update_text(new_text, { { "updated", today } })
    if not stamped then
      return nil, "cannot update " .. path .. ": " .. tostring(uerr)
    end
    local wrote, werr = fsio.write_atomic(path, stamped)
    if not wrote then
      return nil, werr
    end
    return true
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

return M
