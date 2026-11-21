---@module 'tasks_nvim.mdlinks'
---@brief The relative Markdown links of a file: find them, move them one folder deeper, find the dead ones.
---@description
--- A link is the target of `[text](target)`, `![alt](target)` (also `<target>`, with a title after it) or of a
--- reference definition `[id]: target`. Links inside the frontmatter, a fenced code block (```` ``` ```` or `~~~`) or
--- an inline code span are text, not links, and never touched.
---
--- A target is relative when it is none of: empty, an anchor (`#...`), absolute (`/x`, `\x`), a path of some machine
--- (`$REPOS_DIR/x`, `~/x`), or has a scheme (`http:`, `https:`, `mailto:`, `file:`, and a drive letter `C:` reads the
--- same way).
---
--- `shift` is what `mutate.to_folder` needs: a file that moves one folder deeper (`tasks/<slug>.md` ->
--- `tasks/<slug>/<slug>.md`) keeps every link pointing at the same file by gaining one `../`. Links into `assets/`
--- are left alone: they name the folder the move creates.
---
--- Not its job: reading or writing files (the caller does), wikilinks (`tasks_nvim.wikilinks`).

local fsio = require("tasks_nvim.fsio")

local M = {}

---@class Tasks.MdLink
---@field line integer     # 1-based line of the file.
---@field col integer      # First byte of the target in the line.
---@field col_end integer  # Last byte of the target in the line.
---@field target string    # The target as written (without `<` `>`).

---The byte ranges of the inline code spans of a line: a run of backticks up to the next run of the same length. An
---unmatched run is literal text.
---@param line string
---@return integer[][]
local function code_spans(line)
  local spans = {}
  local i = 1
  while true do
    local s, e = line:find("`+", i)
    if not s then
      break
    end
    local ticks, j, closed = e - s + 1, e + 1, nil
    while true do
      local cs, ce = line:find("`+", j)
      if not cs then
        break
      end
      if ce - cs + 1 == ticks then
        closed = ce
        break
      end
      j = ce + 1
    end
    if closed then
      spans[#spans + 1] = { s, closed }
      i = closed + 1
    else
      i = e + 1
    end
  end
  return spans
end

---@param spans integer[][]
---@param pos integer
---@return boolean
local function in_spans(spans, pos)
  for _, sp in ipairs(spans) do
    if pos >= sp[1] and pos <= sp[2] then
      return true
    end
  end
  return false
end

---The links of one line that lies outside any code block.
---@param line string
---@param lnum integer
---@param out Tasks.MdLink[]
local function line_links(line, lnum, out)
  local spans = code_spans(line)
  -- a reference definition: `[id]: target`
  local pre, def = line:match("^(%s*%[[^%]]+%]:%s*)(%S+)")
  if pre and not def:match("^<") and not in_spans(spans, #pre + 1) then
    out[#out + 1] = { line = lnum, col = #pre + 1, col_end = #pre + #def, target = def }
  end
  local init = 1
  while true do
    local s = line:find("](", init, true)
    if not s then
      break
    end
    init = s + 2
    -- a `](` with no `[` before it on the line is text, not a link
    local open = line:find("[", 1, true)
    if open and open < s and not in_spans(spans, s) then
      local ts, te = s + 2, nil
      if line:sub(ts, ts) == "<" then
        local close = line:find(">", ts + 1, true)
        if close then
          ts, te = ts + 1, close - 1
        end
      else
        -- up to the `)` that closes the link (balanced parentheses inside) or the blank before a title
        local e, depth = ts, 0
        while e <= #line do
          local c = line:sub(e, e)
          if c == "(" then
            depth = depth + 1
          elseif c == ")" then
            if depth == 0 then
              break
            end
            depth = depth - 1
          elseif c:match("%s") then
            break
          end
          e = e + 1
        end
        te = e - 1
      end
      if te and te >= ts then
        out[#out + 1] = { line = lnum, col = ts, col_end = te, target = line:sub(ts, te) }
      end
    end
  end
end

---Every link of `text` outside the frontmatter and code, in the order of the file.
---@param text string
---@return Tasks.MdLink[]
function M.scan(text)
  local out = {}
  local lnum = 0
  local front = false
  local fence ---@type string|nil  # the opening run (```` ``` ```` or `~~~`, maybe longer)
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    lnum = lnum + 1
    if lnum == 1 and line:match("^%-%-%-%s*$") then
      front = true
    elseif front then
      if line:match("^%-%-%-%s*$") or line:match("^%.%.%.%s*$") then
        front = false
      end
    elseif fence then
      local run = line:match("^%s*(" .. fence:sub(1, 1):gsub("%p", "%%%0") .. "+)%s*$")
      if run and #run >= #fence then
        fence = nil
      end
    else
      local run = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
      if run then
        fence = run
      else
        line_links(line, lnum, out)
      end
    end
  end
  return out
end

---True when `target` names a file relative to the file it stands in (see the module head).
---@param target string
---@return boolean
function M.is_relative(target)
  return target ~= ""
    and not target:match("^#")
    and not target:match("^[/\\]")
    -- `$REPOS_DIR/x.md`, `~/x.md`: a path of some machine, not one beside the file
    and not target:match("^[$~]")
    and not target:match("^%a[%w+.%-]*:")
end

---True for a link into the `assets/` folder of the file's own folder form.
---@param target string
---@return boolean
function M.is_asset(target)
  return target:match("^assets/") ~= nil or target:match("^%./assets/") ~= nil
end

---`text` for the same file one folder deeper: every relative link outside `assets/` gains a `../` (`./x` becomes
---`../x`). Line ends stay as they are.
---@param text string
---@return string text
---@return integer count  # links changed
function M.shift(text)
  local by_line = {}
  local count = 0
  for _, l in ipairs(M.scan(text)) do
    if M.is_relative(l.target) and not M.is_asset(l.target) then
      by_line[l.line] = by_line[l.line] or {}
      table.insert(by_line[l.line], l)
      count = count + 1
    end
  end
  if count == 0 then
    return text, 0
  end
  local parts, lnum = {}, 0
  -- keep each line's own end (`\r\n` or `\n`); the last piece has none
  for line, eol in text:gmatch("([^\n]*)(\n?)") do
    lnum = lnum + 1
    local links = by_line[lnum]
    if links then
      for i = #links, 1, -1 do
        local l = links[i]
        local new = l.target:match("^%./") and ("../" .. l.target:sub(3)) or ("../" .. l.target)
        line = line:sub(1, l.col - 1) .. new .. line:sub(l.col_end + 1)
      end
    end
    parts[#parts + 1] = line .. eol
    if eol == "" then
      break
    end
  end
  return table.concat(parts), count
end

---The file a relative target names, below `dir`: without `#anchor` and `?query`, percent-escapes decoded.
---@param dir string
---@param target string
---@return string|nil path  # nil: the target names no file (only an anchor or a query)
function M.resolve(dir, target)
  local t = target:gsub("[#?].*$", "")
  if t == "" then
    return nil
  end
  t = t:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  -- `..` is folded by the text, not by the file system: Linux cannot climb out of a folder that is not there yet
  -- (`paths/../tasks/x.md` of a draft whose `paths/` is not made), Windows can. The answer is the same on both.
  local joined = dir .. "/" .. t
  local lead = joined:match("^%a:/") or joined:match("^/+") or ""
  local parts = {}
  for seg in joined:sub(#lead + 1):gmatch("[^/]+") do
    if seg == ".." and #parts > 0 and parts[#parts] ~= ".." then
      parts[#parts] = nil
    elseif seg == ".." and lead ~= "" then
      -- above the root of an absolute path: stays at the root, as the file system does
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return lead .. table.concat(parts, "/")
end

---The first folder outside `root` that `path` lies in: the neighbour repo a link out of the vault leads into
---(`../../../../Literatur/x.md` of a path names `<parent of the vault>/Literatur`). Both are absolute, `/` separated
---(`resolve` gives such a path). nil when `path` is inside `root` or no folder of it can be named.
---@param root string
---@param path string
---@return string|nil folder  # The folder on this machine (to look whether it is there).
---@return string|nil label   # The same folder as seen from `root` (`../Literatur`): no path of this machine.
function M.outside_folder(root, path)
  root = fsio.norm(root)
  local function under(base)
    return path:sub(1, #base + 1) == base .. "/"
  end
  if path == root or under(root) then
    return nil
  end
  local base, up = root, 0
  while not under(base) do
    local parent = fsio.dirname(base)
    if parent == base or parent == "." then
      return nil
    end
    base, up = parent, up + 1
  end
  local first = path:sub(#base + 2):match("^[^/]+")
  if not first then
    return nil
  end
  return base .. "/" .. first, ("../"):rep(up) .. first
end

---The file a relative target names, as a key to compare two spellings: `./assets/x.svg`, `assets/x.svg` and
---`assets/%78.svg` give the same key (without `#anchor` and `?query`, percent-escapes decoded, `.` dropped, `..` folded
---into the segment before it). A `..` with nothing before it stays: `../x` and `x` are two files. nil: the target names
---no file.
---@param target string
---@return string|nil
function M.key(target)
  local t = target:gsub("[#?].*$", "")
  if t == "" then
    return nil
  end
  t = t:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  local parts = {}
  for seg in t:gmatch("[^/]+") do
    if seg == ".." and #parts > 0 and parts[#parts] ~= ".." then
      parts[#parts] = nil
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, "/")
end

---The relative links of `text` whose file (or folder) below `dir` does not exist. `skip(link)` returning true leaves a
---link out (one another check already covers). Note that the answer says whether a path outside the vault exists:
---that is the point (a learning path links to books next to the vault).
---@param text string
---@param dir string
---@param skip? fun(link: Tasks.MdLink): boolean
---@return Tasks.MdLink[]
function M.missing(text, dir, skip)
  local out = {}
  for _, l in ipairs(M.scan(text)) do
    if M.is_relative(l.target) and not (skip and skip(l)) then
      local path = M.resolve(dir, l.target)
      if path and not fsio.stat(path) then
        out[#out + 1] = l
      end
    end
  end
  return out
end

return M
