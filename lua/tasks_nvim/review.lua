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
--- Low-level: no notification here.

local M = {}

M.BEGIN = "<!-- review:begin -->"
M.END = "<!-- review:end -->"

-- A section heading the block may start with; another heading is refused (the block is foreign text).
local HEADINGS = { "## Prüfung", "## Review" }
-- More than this is no review of one task.
local MAX_BLOCK = 32 * 1024

---The last review block of an answer (without the markers, trimmed), or nil.
---@param output string
---@return string|nil
function M.block(output)
  local found
  local from = 1
  while true do
    local b = output:find(M.BEGIN, from, true)
    if not b then
      break
    end
    local e = output:find(M.END, b + #M.BEGIN, true)
    if not e then
      break
    end
    found = output:sub(b + #M.BEGIN, e - 1)
    from = e + #M.END
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
