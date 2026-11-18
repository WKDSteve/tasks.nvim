---@module 'tasks_nvim.sections'
---@brief The `## ` sections of a task's body: read one, set one (replace a section of the same heading, else add it).
---@description
--- Pure text in, text out, on the body below the frontmatter (the caller splits the file, `ops` `set_section` and
--- `review`): a section is its heading line and every line up to the next `## ` heading or the end. Line endings are
--- the caller's: this works on `\n`.

local M = {}

---Splits a body into lines without the trailing blank ones.
---@param text string
---@return string[]
local function lines_of(text)
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

---Where the section `heading` is: its first line and the line before the next `## ` heading (or the last line).
---@param lines string[]
---@param heading string
---@return integer|nil first
---@return integer|nil last
local function find(lines, heading)
  local first
  for i, line in ipairs(lines) do
    if not first then
      if line == heading then
        first = i
      end
    elseif line:match("^## ") then
      return first, i - 1
    end
  end
  return first, first and #lines or nil
end

---The text of the section `heading` (without its heading line, trimmed), or nil when the body has none.
---@param text string
---@param heading string
---@return string|nil
function M.get(text, heading)
  local lines = lines_of(text)
  local first, last = find(lines, heading)
  if not first then
    return nil
  end
  return vim.trim(table.concat(vim.list_slice(lines, first + 1, last), "\n"))
end

---The body with `block` (its first line is the heading) as its section: a section of the same heading is replaced
---(up to the next `## ` heading), else the block is added at the end after one blank line. Ends with one line break.
---@param text string
---@param block string
---@return string
function M.set(text, block)
  local heading = block:match("^[^\n]*")
  local lines = lines_of(text)
  local first, last = find(lines, heading)
  local new = vim.split(block, "\n", { plain = true })
  local out
  if first then
    out = vim.list_slice(lines, 1, first - 1)
    vim.list_extend(out, new)
    if last < #lines then
      out[#out + 1] = ""
      vim.list_extend(out, vim.list_slice(lines, last + 1))
    end
  else
    out = lines
    out[#out + 1] = ""
    vim.list_extend(out, new)
  end
  -- Only the section itself changes: the rest of the text keeps its own blank lines.
  return table.concat(out, "\n") .. "\n"
end

return M
