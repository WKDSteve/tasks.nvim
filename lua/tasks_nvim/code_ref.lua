---@module 'tasks_nvim.code_ref'
---@brief The `code-ref/1` block of a task made from a selection (`:'<,'>Tasks new`).
---@description
--- A task made from marked code carries the code as a fenced block of language `code-ref` in its body (under
--- `## Kontext`): repository, commit, file, lines, language, the symbol when known and an excerpt of at most 4 KiB.
--- DocMap, tasks-desktop and the agent of ai-desktop read the same block; the contract is
--- `appkit/schemas/code-ref/1` (README, schema, goldens). This module
---
--- * `capture` makes the document from a buffer and a line range (git root, HEAD, dirty, relative file, symbol);
--- * `problems` / `blocks` / `task_problems` are the Lua port of `appkit/tools/check-code-ref.py` (the reference of
---   the reader's check; `TESTS/golden/code-ref/` holds the goldens, copied from appkit `94a97ff`);
--- * `render` encodes a document and refuses it when the check finds a problem: an invalid document never becomes a
---   block;
--- * `insert` puts a rendered block into a task file under its context heading, checked again as a task.
---
--- Privacy: the document holds the repository NAME and a repo-relative file, never the path of this machine. The
--- excerpt is code of a person's project: in a private area (`new.private_areas`, `new.private_vaults`) the caller
--- asks before it writes the excerpt (`strip_excerpt`).
---
--- Differences from the Python reference, all on the lenient side of the same input: a JSON number `1.0` reads as the
--- integer 1 (a Lua number has no float form); `\s` and `\b` of the path check are ASCII (plus any byte of a multibyte
--- character counts as a word character).
local M = {}

local fsio = require("tasks_nvim.fsio")

M.SCHEMA = "code-ref/1"
M.FENCE_LANG = "code-ref"
M.MAX_BYTES = 64 * 1024
M.MAX_EXCERPT_BYTES = 4096
local MAX_PATH = 300
local MAX_LINE = 10000000
local LIMITS = {
  symbol = 200,
  ["docmap.node"] = 300,
  ["docmap.fn"] = 200,
  ["telemetry.namespace"] = 100,
  ["telemetry.key"] = 300,
}

-- ── the check (port of tools/check-code-ref.py) ──────────────────────────────

---Number of characters of a UTF-8 string (continuation bytes are not counted).
---@param s string
---@return integer
local function nchars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return #s - (#s - n) -- n counts the non-continuation bytes
end

---Is `s` well-formed UTF-8 (RFC 3629: no overlong form, no surrogate, nothing above U+10FFFF)?
---@param s string
---@return boolean
function M.valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then
      i = i + 1
    else
      local len, min
      if c >= 0xC2 and c <= 0xDF then
        len, min = 2, 0x80
      elseif c >= 0xE0 and c <= 0xEF then
        len, min = 3, 0x800
      elseif c >= 0xF0 and c <= 0xF4 then
        len, min = 4, 0x10000
      else
        return false
      end
      if i + len - 1 > n then
        return false
      end
      local cp = c % (len == 2 and 0x20 or len == 3 and 0x10 or 0x08)
      for k = 1, len - 1 do
        local b = s:byte(i + k)
        if b < 0x80 or b > 0xBF then
          return false
        end
        cp = cp * 64 + (b - 0x80)
      end
      if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return false
      end
      i = i + len
    end
  end
  return true
end

---A control character other than tab, line feed and carriage return, or one of the C1 block (U+0080..U+009F).
---@param s string
---@return boolean
local function has_control(s)
  for i = 1, #s do
    local b = s:byte(i)
    if (b <= 0x08) or b == 0x0B or b == 0x0C or (b >= 0x0E and b <= 0x1F) or b == 0x7F then
      return true
    end
    if b == 0xC2 then
      local nxt = s:byte(i + 1)
      if nxt and nxt >= 0x80 and nxt <= 0x9F then
        return true
      end
    end
  end
  return false
end

local SPACE = { [32] = true, [9] = true, [10] = true, [11] = true, [12] = true, [13] = true }

---A word character as `\w` of the reference (ASCII, and every byte of a multibyte character).
---@param b integer|nil
---@return boolean
local function word_byte(b)
  return b ~= nil
    and (
      b == 95
      or (b >= 48 and b <= 57)
      or (b >= 65 and b <= 90)
      or (b >= 97 and b <= 122)
      or b >= 128
    )
end

---One word of `text` that leaves the repository: an absolute path, a home, a `..` segment.
---@param text string
---@return boolean
function M.leaves_repo(text)
  local n = #text
  local function sep(b)
    return b == 47 or b == 92
  end
  for p = 1, n + 1 do
    local prev = p > 1 and text:byte(p - 1) or nil
    local b, b2 = text:byte(p), text:byte(p + 1)
    -- first form: `(^|[\s"'=])` then a root
    if p == 1 or (prev and (SPACE[prev] or prev == 34 or prev == 39 or prev == 61)) then
      if b and sep(b) then
        return true
      end
      if
        b
        and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
        and b2 == 58
        and sep(text:byte(p + 2))
      then
        return true
      end
      if b == 126 and sep(b2) then
        return true
      end
      if b == 36 then
        local q = p + 1
        if text:byte(q) == 123 then
          q = q + 1
        end
        if text:sub(q, q + 3) == "HOME" and not word_byte(text:byte(q + 4)) then
          return true
        end
      end
      if b == 37 then
        local q = p + 1
        while
          text:byte(q)
          and (
            (text:byte(q) >= 65 and text:byte(q) <= 90)
            or (text:byte(q) >= 97 and text:byte(q) <= 122)
          )
        do
          q = q + 1
        end
        if q > p + 1 and text:byte(q) == 37 then
          return true
        end
      end
    end
    -- second form: `(^|[\s"'=/\\])` then `..` then a separator, a space or the end
    if
      p == 1 or (prev and (SPACE[prev] or prev == 34 or prev == 39 or prev == 61 or sep(prev)))
    then
      if b == 46 and b2 == 46 then
        local after = text:byte(p + 2)
        if after == nil or sep(after) or SPACE[after] then
          return true
        end
      end
    end
  end
  return false
end

local function is_int(v)
  return type(v) == "number" and v % 1 == 0 and v == v and v ~= math.huge and v ~= -math.huge
end

---A value of the document by key; JSON `null` reads as absent (as `dict.get` does for `None`).
---@param t table
---@param key string
---@return any
local function get(t, key)
  local v = t[key]
  if v == vim.NIL then
    return nil
  end
  return v
end

local function is_plain(v, limit)
  return type(v) == "string" and #v > 0 and nchars(v) <= limit
end

local function is_object(v)
  if type(v) ~= "table" then
    return false
  end
  if next(v) == nil then
    return getmetatable(v) == getmetatable(vim.empty_dict())
  end
  return not vim.islist(v)
end

---@param file any
---@param out string[]
local function check_file(file, out)
  if type(file) ~= "string" or file == "" then
    out[#out + 1] = "file is missing"
  elseif nchars(file) > MAX_PATH then
    out[#out + 1] = ("file is longer than %d"):format(MAX_PATH)
  elseif M.leaves_repo(file) then
    out[#out + 1] = "file leaves the repository"
  elseif file:find("\\", 1, true) or file:find(":", 1, true) or file:find("\0", 1, true) then
    out[#out + 1] = "file is not a plain forward-slash path"
  else
    for part in (file .. "/"):gmatch("([^/]*)/") do
      if part == "" or part == "." then
        out[#out + 1] = "file is not canonical (empty or . segment)"
        break
      end
    end
  end
end

---`docmap` and `telemetry`: an object of plain non-empty strings; `required` of the `fields` are required.
local function check_pair(doc, key, fields, required, out)
  local value = get(doc, key)
  if value == nil then
    return
  end
  if not is_object(value) then
    out[#out + 1] = key .. " is not an object"
    return
  end
  for index, field in ipairs(fields) do
    local text = get(value, field)
    local name = key .. "." .. field
    if not (text == nil and index > required) and not is_plain(text, LIMITS[name]) then
      out[#out + 1] = ("%s is missing or longer than %d"):format(name, LIMITS[name])
    end
  end
  local node = get(value, "node")
  if key == "docmap" and type(node) == "string" and M.leaves_repo(node) then
    out[#out + 1] = "docmap.node leaves the repository"
  end
end

---Does any string of the value (keys included) hold a control character? A loop, not recursion.
local function any_control(value)
  local stack = { value }
  while #stack > 0 do
    local item = table.remove(stack)
    if type(item) == "string" then
      if has_control(item) then
        return true
      end
    elseif type(item) == "table" then
      for k, v in pairs(item) do
        stack[#stack + 1] = k
        stack[#stack + 1] = v
      end
    end
  end
  return false
end

---Every reason to refuse `raw` (a string of bytes), empty when a reader may use the reference.
---@param raw string
---@return string[] problems
function M.problems(raw)
  if #raw > M.MAX_BYTES then
    return { ("larger than %d bytes"):format(M.MAX_BYTES) }
  end
  if not M.valid_utf8(raw) then
    return { "not JSON in UTF-8" }
  end
  local ok, doc = pcall(vim.json.decode, raw)
  if not ok then
    return { "not JSON in UTF-8" }
  end
  if not is_object(doc) then
    return { "not a JSON object" }
  end
  local schema = get(doc, "schema")
  if schema ~= M.SCHEMA then
    return { ("schema %s is not %s"):format(vim.inspect(schema), M.SCHEMA) }
  end
  local out = {}
  local repo = get(doc, "repo")
  if
    not (type(repo) == "string" and #repo <= 100 and repo:match("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
  then
    out[#out + 1] = "repo is missing or not a plain name"
  end
  check_file(get(doc, "file"), out)
  local lines = get(doc, "lines")
  if
    not (
      type(lines) == "table"
      and vim.islist(lines)
      and #lines == 2
      and is_int(lines[1])
      and is_int(lines[2])
    )
  then
    out[#out + 1] = "lines is not two integers"
  elseif not (lines[1] >= 1 and lines[1] <= lines[2] and lines[2] <= MAX_LINE) then
    out[#out + 1] = ("lines is not 1 <= first <= last <= %d"):format(MAX_LINE)
  end
  local sha = get(doc, "sha")
  if
    sha ~= nil
    and not (type(sha) == "string" and (#sha == 40 or #sha == 64) and sha:match("^[0-9a-f]+$"))
  then
    out[#out + 1] = "sha is not 40 or 64 lowercase hex characters"
  end
  if doc.dirty ~= nil and type(doc.dirty) ~= "boolean" then
    out[#out + 1] = "dirty is not a boolean"
  end
  if doc.truncated ~= nil and type(doc.truncated) ~= "boolean" then
    out[#out + 1] = "truncated is not a boolean"
  end
  local lang = get(doc, "lang")
  if
    lang ~= nil
    and not (type(lang) == "string" and #lang <= 32 and lang:match("^[a-z0-9][a-z0-9+#._-]*$"))
  then
    out[#out + 1] = "lang is not a plain name"
  end
  local symbol = get(doc, "symbol")
  if symbol ~= nil and not is_plain(symbol, LIMITS.symbol) then
    out[#out + 1] = ("symbol is empty or longer than %d"):format(LIMITS.symbol)
  end
  local excerpt = get(doc, "excerpt")
  if excerpt ~= nil then
    if type(excerpt) ~= "string" then
      out[#out + 1] = "excerpt is not a string"
    elseif #excerpt > M.MAX_EXCERPT_BYTES then
      out[#out + 1] = ("excerpt is longer than %d bytes"):format(M.MAX_EXCERPT_BYTES)
    end
  end
  if doc.class ~= nil and doc.class ~= "public" and doc.class ~= "internal" then
    out[#out + 1] = "class is not public or internal"
  end
  check_pair(doc, "docmap", { "node", "fn" }, 1, out)
  check_pair(doc, "telemetry", { "namespace", "key" }, 2, out)
  if any_control(doc) then
    out[#out + 1] = "a field holds a control character"
  end
  return out
end

---The text of every closed fenced block of language `code-ref` in the body of a task. A fence opens on a line of
---three or more backticks and closes on a line of at least as many; a block of any other language, and anything
---inside it, is skipped, so a `code-ref` shown inside a longer fence is not a reference. The frontmatter is not body.
---An unclosed block is dropped.
---@param markdown string
---@return string[]
function M.blocks(markdown)
  local lines = vim.split((markdown:gsub("\r\n", "\n")), "\n", { plain = true })
  local start = 1
  if lines[1] and lines[1]:gsub("%s+$", "") == "---" then
    for index = 2, #lines do
      if lines[index]:gsub("%s+$", "") == "---" then
        start = index + 1
        break
      end
    end
  end
  local found, fence, mine, body = {}, nil, false, {}
  for index = start, #lines do
    local line = lines[index]
    if fence == nil then
      local spaces, ticks, info = line:match("^( *)(`+)([^`]*)$")
      if spaces and #spaces <= 3 and #ticks >= 3 then
        fence, mine, body = #ticks, vim.trim(info) == M.FENCE_LANG, {}
      end
    else
      local spaces, ticks = line:match("^( *)(`+)%s*$")
      if spaces and #spaces <= 3 and #ticks >= fence then
        if mine then
          found[#found + 1] = table.concat(body, "\n")
        end
        fence = nil
      elseif mine then
        body[#body + 1] = line
      end
    end
  end
  return found
end

---`{ index, problems }` for every `code-ref` block of a task; empty problems means usable.
---@param markdown string
---@return { index: integer, problems: string[] }[]
function M.task_problems(markdown)
  local out = {}
  for i, text in ipairs(M.blocks(markdown)) do
    out[i] = { index = i, problems = M.problems(text) }
  end
  return out
end

-- ── making the document ──────────────────────────────────────────────────────

local KEY_ORDER = {
  "schema",
  "repo",
  "sha",
  "dirty",
  "file",
  "lines",
  "lang",
  "symbol",
  "excerpt",
  "truncated",
  "docmap",
  "telemetry",
  "class",
}

---A JSON value on one line (`/` is not escaped: the encoder of Neovim writes `\/`).
---@param value any
---@return string
local function json_one(value)
  local text = vim.json.encode(value)
  return (text:gsub("\\(.)", function(c)
    if c == "/" then
      return "/"
    end
  end))
end

---The document as JSON text, one field per line in the order of the contract (the form of the goldens).
---@param doc table
---@return string
function M.encode(doc)
  local parts = {}
  for _, key in ipairs(KEY_ORDER) do
    local value = doc[key]
    if value ~= nil then
      local text
      if key == "lines" then
        text = ("[%d, %d]"):format(value[1], value[2])
      elseif key == "docmap" then
        text = value.fn
            and ('{ "node": %s, "fn": %s }'):format(json_one(value.node), json_one(value.fn))
          or ('{ "node": %s }'):format(json_one(value.node))
      elseif key == "telemetry" then
        text = ('{ "namespace": %s, "key": %s }'):format(
          json_one(value.namespace),
          json_one(value.key)
        )
      else
        text = json_one(value)
      end
      parts[#parts + 1] = ("  %s: %s"):format(json_one(key), text)
    end
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end

---The fenced block of a document; `nil, problems` when the check of the reader finds any.
---@param doc table
---@return string|nil block
---@return string[]|nil problems
function M.render(doc)
  local ok, text = pcall(M.encode, doc)
  if not ok then
    return nil, { "the document cannot be written: " .. tostring(text) }
  end
  local found = M.problems(text)
  if #found > 0 then
    return nil, found
  end
  return "```" .. M.FENCE_LANG .. "\n" .. text .. "\n```"
end

---A copy of the document without the excerpt (and its `truncated`): what is written where the person said no.
---@param doc table
---@return table
function M.strip_excerpt(doc)
  local copy = vim.deepcopy(doc)
  copy.excerpt, copy.truncated = nil, nil
  return copy
end

---Cut `text` to `limit` bytes on a whole character.
---@param text string
---@param limit integer
---@return string text
---@return boolean truncated
function M.cut(text, limit)
  if #text <= limit then
    return text, false
  end
  local cut = limit
  while cut > 0 do
    local b = text:byte(cut + 1)
    if b and b >= 0x80 and b <= 0xBF then
      cut = cut - 1
    else
      break
    end
  end
  return text:sub(1, cut), true
end

---Replace what the check refuses in a text (a control character other than tab, line break and carriage return, the C1
---block) by a space, so a form feed in a source file does not cost the whole block.
---@param text string
---@return string
local function clean(text)
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", " ")
  return (text:gsub("\194[\128-\159]", " "))
end

---The file of `path` relative to its git root (forward slashes) and the root; without a git root relative to the
---working directory, and no root.
---@param path string  absolute or relative
---@return string where
---@return string|nil root
function M.relative(path)
  local abs = fsio.norm(vim.fn.fnamemodify(path, ":p"))
  local root = vim.fs.root(abs, ".git")
  local where
  if root then
    root = fsio.norm(root):gsub("/+$", "")
    -- Drive letters differ in case on Windows (`E:` and `e:`): compare without it.
    if abs:sub(1, #root + 1):lower() == (root .. "/"):lower() then
      where = abs:sub(#root + 2)
    else
      root = nil
    end
  end
  return where or fsio.norm(vim.fn.fnamemodify(path, ":.")), root
end

---@param root string
---@param args string[]  git arguments
---@return string|nil out  # trimmed stdout; nil when git fails or is missing
local function git(root, args)
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait(10000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
end

---The name of the repository whose checkout (or worktree) is at `root`: the folder of the main `.git`, so a worktree
---`<repo>/.claude/worktrees/x` is named `<repo>`, not `x`.
---@param root string
---@return string
function M.repo_name(root)
  return (M.identity(root))
end

---The name of the repository (`repo_name`) and the HEAD commit, with one git call; the commit is nil in a repository
---without a commit.
---@param root string
---@return string name
---@return string|nil sha
function M.identity(root)
  local out = git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir", "HEAD" })
  local common, sha
  if out then
    common, sha = out:match("^([^\n]+)\n(%x+)$")
  else
    -- no commit yet: HEAD does not resolve, the common directory alone does
    common = git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  end
  local name = root:match("([^/]+)$") or ""
  if common and common ~= "" then
    common = fsio.norm(common)
    if not common:find("/.git/modules/", 1, true) and common:match("/%.git$") then
      name = (common:gsub("/%.git$", ""):match("([^/]+)$")) or name
    end
  end
  return name, sha
end

---The name the code goes by at the start of the range: the nearest function, method or class of the tree-sitter
---parse of the buffer, when there is one (free text for the reader; nothing is guessed without a parser).
---@param buf integer
---@param first_line integer
---@return string|nil
function M.symbol(buf, first_line)
  local ok, name = pcall(function()
    local line = vim.api.nvim_buf_get_lines(buf, first_line - 1, first_line, false)[1] or ""
    local col = #(line:match("^%s*") or "")
    local parser = vim.treesitter.get_parser(buf, nil, { error = false })
    if not parser then
      return nil
    end
    parser:parse()
    local node = vim.treesitter.get_node({ bufnr = buf, pos = { first_line - 1, col } })
    while node do
      local kind = node:type()
      if
        kind:find("function")
        or kind:find("method")
        or kind:find("class")
        or kind:find("struct")
        or kind:find("impl")
      then
        local named = node:field("name")[1] or node:field("type")[1]
        if named then
          return vim.treesitter.get_node_text(named, buf)
        end
      end
      node = node:parent()
    end
  end)
  if
    ok
    and type(name) == "string"
    and name ~= ""
    and nchars(name) <= LIMITS.symbol
    and not has_control(name)
  then
    return (name:gsub("%s+", " "))
  end
end

---The document of a range of a buffer. `nil, reason` when there is none to make: the buffer is no real file, the
---file is not in a git repository, or git is not there. The excerpt is the text of the BUFFER (what the person sees,
---also what is not saved), cut to 4 KiB on a whole character.
---@param buf integer
---@param first_line integer
---@param last_line integer
---@return table|nil doc
---@return string|nil reason
function M.capture(buf, first_line, last_line)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" or file:match("^%a[%w+.-]*://") or vim.bo[buf].buftype ~= "" then
    return nil, "the buffer is no file"
  end
  local where, root = M.relative(file)
  if not root then
    return nil, "the file is not in a git repository"
  end
  local name, sha = M.identity(root)
  local doc = { schema = M.SCHEMA, repo = name, file = where, lines = { first_line, last_line } }
  if sha and sha:match("^[0-9a-f]+$") and (#sha == 40 or #sha == 64) then
    doc.sha = sha
    local status = git(root, { "status", "--porcelain", "--", where })
    doc.dirty = vim.bo[buf].modified or (status ~= nil and status ~= "")
  elseif vim.bo[buf].modified then
    -- no commit yet: the lines refer to no commit
    doc.dirty = true
  end
  local ft = (vim.bo[buf].filetype or ""):lower()
  if ft ~= "" and #ft <= 32 and ft:match("^[a-z0-9][a-z0-9+#._-]*$") then
    doc.lang = ft
  end
  doc.symbol = M.symbol(buf, first_line)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, first_line - 1, last_line, false), "\n")
  if M.valid_utf8(text) then
    text = clean(text)
    local excerpt, truncated = M.cut(text, M.MAX_EXCERPT_BYTES)
    doc.excerpt, doc.truncated = excerpt, truncated
  end
  return doc
end

-- ── privacy ──────────────────────────────────────────────────────────────────

---Is `area` of the vault at `root` private: named in `new.private_areas`, or the vault folder is named in
---`new.private_vaults` (default `tricentis-vault`)? The excerpt of a private area is written only after a yes.
---@param area string
---@param root string|nil
---@return boolean
function M.is_private(area, root)
  local cfg = require("tasks_nvim.config").get().new or {}
  if vim.tbl_contains(cfg.private_areas or {}, area) then
    return true
  end
  if root then
    local folder = fsio.norm(root):match("([^/]+)$")
    if folder and vim.tbl_contains(cfg.private_vaults or {}, folder) then
      return true
    end
  end
  return false
end

-- ── into the task ────────────────────────────────────────────────────────────

---Put `block` into the task file at `path`, under its first `## Kontext` / `## Context` heading (an invisible
---placeholder line of the template there is replaced), else at the end under a new `## Kontext`. The result is
---checked as a task: only a text whose `code-ref` blocks all pass is written.
---@param path string
---@param block string
---@return boolean ok
---@return string|nil err
function M.insert(path, block)
  local raw, rerr = fsio.read(path)
  if not raw then
    return false, rerr
  end
  local crlf = raw:find("\r\n", 1, true) ~= nil
  local lines = vim.split(fsio.lf(raw), "\n", { plain = true })
  local start = 1
  if lines[1] == "---" then
    for i = 2, #lines do
      if lines[i] == "---" then
        start = i + 1
        break
      end
    end
  end
  local at
  for i = start, #lines do
    if lines[i]:match("^## Kontext%s*$") or lines[i]:match("^## Context%s*$") then
      at = i
      break
    end
  end
  local out = {}
  if at then
    for i = 1, at do
      out[#out + 1] = lines[i]
    end
    out[#out + 1] = ""
    vim.list_extend(out, vim.split(block, "\n", { plain = true }))
    local nxt = at + 1
    while lines[nxt] ~= nil and vim.trim(lines[nxt]) == "" do
      nxt = nxt + 1
    end
    if lines[nxt] and lines[nxt]:match("^<!%-%-.*%-%->%s*$") then
      -- the placeholder is replaced by the block
      nxt = nxt + 1
    else
      nxt = at + 1
    end
    out[#out + 1] = ""
    for i = nxt, #lines do
      if i > nxt or vim.trim(lines[i]) ~= "" or lines[i] == nil then
        out[#out + 1] = lines[i]
      end
    end
  else
    out = vim.deepcopy(lines)
    while #out > 0 and out[#out] == "" do
      out[#out] = nil
    end
    out[#out + 1] = ""
    out[#out + 1] = "## Kontext"
    out[#out + 1] = ""
    vim.list_extend(out, vim.split(block, "\n", { plain = true }))
    out[#out + 1] = ""
  end
  local text = table.concat(out, "\n")
  for _, found in ipairs(M.task_problems(text)) do
    if #found.problems > 0 then
      return false, "the code-ref block is invalid: " .. table.concat(found.problems, "; ")
    end
  end
  if #M.blocks(text) == 0 then
    return false, "the code-ref block did not land in the task"
  end
  if crlf then
    text = text:gsub("\n", "\r\n")
  end
  return fsio.write_atomic(path, text)
end

return M
