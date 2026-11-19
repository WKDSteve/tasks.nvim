---@module 'tasks_nvim.lernbaum'
---@brief The learning tree: the checkbox tree of `## Lernpunkte` in a learning path or a task, read and written back.
---@description
--- One syntax for a path file (`<area>/ROADMAP/paths/<slug>.md`) and the `## Lernpunkte` section of a task, so that a
--- node promoted to a task takes its subtree along:
---
---     - [ ] Lua lernen {#lua}
---       - [x] [Manual, chapter 3](https://www.lua.org/manual/5.4/)
---         > Note: the precedence of `..` and `^`.
---       - [~] [Programming in Lua](https://www.lua.org/pil/) – Grund: only chapter 1 was needed
---       - [ ] C-Compiler erlernen → learning/c-compiler {#cc}
---       - [-] Lua-JIT internals – Grund: not needed for the goal
---
--- Marks: `[ ]` open, `[x]` learned, `[~]` seen (a reason is required), `[-]` dropped (a reason is required), `[!]`
--- blocked. A node with children has no mark of its own: its state is derived from its leaves (all learned: learned;
--- none closed: open; else partial), and it is closed when every leaf is. Progress is always counted apart: learned,
--- seen, dropped, open (blocked ones counted as open and once more as blocked).
---
--- A node line reads `<label>[ → <id>][ – Grund: <reason>][ {#key}]`; the key comes last, the reason after the label
--- (also `Reason:`, and `—` or `-` as the dash), the arrow names the task the node was promoted to. A `> ` line indented
--- below a node is its note. Every other line of the section (prose, blank lines, comments, code fences) is kept as it
--- is: `render` gives back the text byte for byte, only the nodes changed with `set_state` are written anew.
---
--- Pure Lua, no I/O. Not its job: whether an arrow names a task that exists, cycles over files, images on disk
--- (`check`); the path file itself (`tasks_nvim.paths`).

local M = {}

---The headings of the section, German and English.
M.HEADINGS = { "Lernpunkte", "Learning points" }

---Mark -> state.
---@type table<string, string>
M.MARKS = {
  [" "] = "open",
  x = "learned",
  X = "learned",
  ["~"] = "seen",
  ["-"] = "dropped",
  ["!"] = "blocked",
}

---State -> the mark `set_state` writes.
---@type table<string, string>
M.MARK_OF = { open = " ", learned = "x", seen = "~", dropped = "-", blocked = "!" }

---The states that close a leaf.
local CLOSED = { learned = true, seen = true, dropped = true }

---The states that need a reason.
M.NEEDS_REASON = { seen = true, dropped = true }

local ARROW = "\226\134\146" -- U+2192
local EN_DASH = "\226\128\147" -- U+2013
local EM_DASH = "\226\128\148" -- U+2014

---The separators of a reason, the first one found wins.
local REASON_SEPARATORS = {}
for _, dash in ipairs({ EN_DASH, EM_DASH, "-" }) do
  for _, word in ipairs({ "Grund:", "Reason:" }) do
    REASON_SEPARATORS[#REASON_SEPARATORS + 1] = " " .. dash .. " " .. word
  end
end

---@class Tasks.LernNode
---@field index integer          # Position in `tree.nodes` (document order), 1-based.
---@field line integer           # The line of the body text it stands on, 1-based.
---@field indent integer         # Width of the leading white space (a tab counts 4).
---@field depth integer          # 0 for a root node.
---@field mark string            # The character between the brackets.
---@field state? string          # `open`, `learned`, `seen`, `dropped`, `blocked`; nil for an unknown mark.
---@field label string           # The text without arrow, reason and key, as written.
---@field key? string
---@field reason? string
---@field promoted? string       # The id after the arrow.
---@field link? string           # The first link of the label that is not an image.
---@field image? string          # The first image of the label or the note.
---@field note? string           # The `> ` lines below the node, joined by newlines.
---@field children Tasks.LernNode[]
---@field parent? Tasks.LernNode
---@field derived string         # The state shown: a leaf's own (unknown mark: open); a parent's learned, partial or open.
---@field closed boolean
---@field progress Tasks.LernProgress
---@field dirty? boolean         # Changed by `set_state`: `render` writes the line anew.
---@field prefix string          # The text before the mark: indent and bullet, as written.
---@field cr string              # `"\r"` when the line ended with CRLF.

---@class Tasks.LernProgress
---@field learned integer
---@field seen integer
---@field dropped integer
---@field open integer           # Open and blocked leaves (and leaves with an unknown mark).
---@field blocked integer
---@field total integer

---@class Tasks.LernProblem
---@field code string
---@field line integer
---@field key? string
---@field message string

---@class Tasks.LernTree
---@field has_section boolean
---@field roots Tasks.LernNode[]
---@field nodes Tasks.LernNode[]   # Every node in document order.
---@field by_key table<string, Tasks.LernNode>  # The first node of each key.
---@field progress Tasks.LernProgress
---@field problems Tasks.LernProblem[]
---@field lines string[]           # The body split at `\n` (a CR stays on its line).

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param ws string
---@return integer
local function width(ws)
  local n = 0
  for c in ws:gmatch(".") do
    n = n + (c == "\t" and 4 or 1)
  end
  return n
end

---@param name string
---@return boolean
local function is_heading_of_section(name)
  for _, h in ipairs(M.HEADINGS) do
    if name:lower() == h:lower() then
      return true
    end
  end
  return false
end

---Whether a key has the form of a slug (lower case letters, digits, dashes).
---@param key string
---@return boolean
function M.valid_key(key)
  return key:match("^[a-z0-9][a-z0-9%-]*$") ~= nil and #key <= 64
end

---Whether a text is an id `<area>/<slug>` (the form only; whether it exists is `check`'s matter).
---@param id string
---@return boolean
local function is_id(id)
  local area, slug = id:match("^([^/%s]+)/([^/%s]+)$")
  return area ~= nil and slug:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
end

---Split the text after the mark into label, arrow, reason and key.
---@param text string
---@return { label: string, key?: string, reason?: string, promoted?: string, arrow_bad?: string }
function M.split(text)
  local rest = text:gsub("%s+$", "")
  local out = {}
  local before, key = rest:match("^(.-)%s*{#([^{}%s]+)}$")
  if before then
    rest, out.key = before, key
  end
  local at, sep
  for _, s in ipairs(REASON_SEPARATORS) do
    local i = rest:find(s, 1, true)
    if i and (not at or i < at) then
      at, sep = i, s
    end
  end
  if at then
    out.reason = trim(rest:sub(at + #sep))
    if out.reason == "" then
      out.reason = nil
    end
    rest = rest:sub(1, at - 1)
  end
  for _, arrow in ipairs({ ARROW, "->" }) do
    local head, target = rest:match("^(.-)%s+" .. arrow:gsub("%-", "%%-") .. "%s*(%S*)$")
    -- `->` is an arrow only before an id ("Lua -> C" is text); `→` is always one, and a bad target is named
    if head and (arrow == ARROW or is_id(target)) then
      if is_id(target) then
        out.promoted = target
      else
        out.arrow_bad = target
      end
      rest = head
      break
    end
  end
  out.label = rest
  return out
end

---The first link (not an image) and the first image of a text.
---@param text string
---@return string|nil link
---@return string|nil image
local function links_of(text)
  local image = text:match("!%[[^%]]*%]%(([^%)%s]+)[^%)]*%)")
  local stripped = text:gsub("!%[[^%]]*%]%([^%)]*%)", "")
  local link = stripped:match("%[[^%]]*%]%(([^%)%s]+)[^%)]*%)")
  return link, image
end

---@return Tasks.LernProgress
local function zero()
  return { learned = 0, seen = 0, dropped = 0, open = 0, blocked = 0, total = 0 }
end

---@param into Tasks.LernProgress
---@param from Tasks.LernProgress
local function add_progress(into, from)
  for k, v in pairs(from) do
    into[k] = into[k] + v
  end
end

---Derive state, closedness and progress of a node from its leaves (recursive).
---@param node Tasks.LernNode
local function derive(node)
  local p = zero()
  if #node.children == 0 then
    local s = node.state or "open"
    p.total = 1
    if s == "blocked" then
      p.open, p.blocked = 1, 1
    elseif CLOSED[s] then
      p[s] = 1
    else
      p.open = 1
    end
    node.derived = node.state or "open"
    node.closed = CLOSED[s] == true
  else
    for _, c in ipairs(node.children) do
      derive(c)
      add_progress(p, c.progress)
    end
    node.closed = p.open == 0
    if p.learned == p.total then
      node.derived = "learned"
    elseif p.learned + p.seen + p.dropped == 0 then
      node.derived = "open"
    else
      node.derived = "partial"
    end
  end
  node.progress = p
end

---Read the learning tree of a body (the text below the frontmatter). Without a `## Lernpunkte` section the tree is
---empty (`has_section = false`). Never raises.
---@param body string
---@return Tasks.LernTree
function M.parse(body)
  local lines = vim.split(body or "", "\n", { plain = true })
  ---@type Tasks.LernTree
  local tree = {
    has_section = false,
    roots = {},
    nodes = {},
    by_key = {},
    progress = zero(),
    problems = {},
    lines = lines,
  }
  local function problem(code, line, msg, key)
    tree.problems[#tree.problems + 1] = { code = code, line = line, key = key, message = msg }
  end
  local inside, fence = false, nil
  local stack = {}
  local last
  for i, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    if fence then
      if line:match("^%s*" .. fence) then
        fence = nil
      end
    elseif line:match("^%s*```") or line:match("^%s*~~~") then
      -- a heading or a checkbox inside a code block is text, in the section and outside it
      fence = line:match("^%s*(```)") or "~~~"
      last = nil
    else
      local hashes, name = line:match("^(#+)%s+(.-)%s*$")
      if hashes and #hashes <= 2 then
        inside = #hashes == 2 and is_heading_of_section(name)
        if inside then
          tree.has_section = true
        end
        stack, last = {}, nil
      elseif inside then
        local ws, bullet, mark, text = line:match("^(%s*)([-*+])%s%[(.)%]%s?(.*)$")
        if ws then
          local indent = width(ws)
          while #stack > 0 and stack[#stack].indent >= indent do
            table.remove(stack)
          end
          local parts = M.split(text)
          local link, image = links_of(parts.label)
          ---@type Tasks.LernNode
          local node = {
            index = #tree.nodes + 1,
            line = i,
            indent = indent,
            depth = #stack,
            mark = mark,
            state = M.MARKS[mark],
            label = parts.label,
            key = parts.key,
            reason = parts.reason,
            promoted = parts.promoted,
            link = link,
            image = image,
            children = {},
            parent = stack[#stack],
            derived = "open",
            closed = false,
            progress = zero(),
            prefix = ws .. bullet .. " ",
            cr = raw:sub(-1) == "\r" and "\r" or "",
          }
          tree.nodes[#tree.nodes + 1] = node
          if node.parent then
            table.insert(node.parent.children, node)
          else
            table.insert(tree.roots, node)
          end
          stack[#stack + 1] = node
          last = node
          if not node.state then
            problem(
              "path-bad-mark",
              i,
              ("unknown mark [%s] (expected [ ], [x], [~], [-] or [!])"):format(mark)
            )
          end
          if parts.key then
            if not M.valid_key(parts.key) then
              problem(
                "path-bad-key",
                i,
                ("key {#%s} is no slug (a-z, 0-9, -)"):format(parts.key),
                parts.key
              )
            elseif tree.by_key[parts.key] then
              problem(
                "path-duplicate-key",
                i,
                ("key {#%s} is already on line %d"):format(parts.key, tree.by_key[parts.key].line),
                parts.key
              )
            else
              tree.by_key[parts.key] = node
            end
          end
          if parts.arrow_bad then
            problem(
              "path-bad-arrow",
              i,
              ("the arrow names no id <area>/<slug>: '%s'"):format(parts.arrow_bad),
              parts.key
            )
          end
          if
            node.image and (node.image:find("..", 1, true) or not node.image:match("^assets/"))
          then
            problem(
              "path-image-outside",
              i,
              "an image must be a file below assets/ of the path or task: " .. node.image,
              parts.key
            )
          end
        else
          local nws, note = line:match("^(%s*)>%s?(.*)$")
          if nws and last and width(nws) > last.indent then
            last.note = last.note and (last.note .. "\n" .. note) or note
            if not last.image then
              local _, image = links_of(note)
              last.image = image
            end
          elseif line:match("%S") then
            last = nil
          end
        end
      end
    end
  end
  for _, root in ipairs(tree.roots) do
    derive(root)
    add_progress(tree.progress, root.progress)
  end
  -- a leaf seen or dropped needs its reason; a parent has no mark of its own, so none of its own
  for _, node in ipairs(tree.nodes) do
    if #node.children == 0 and M.NEEDS_REASON[node.state or ""] and not node.reason then
      problem(
        "path-reason-missing",
        node.line,
        ("[%s] needs a reason (– Grund: …)"):format(node.mark),
        node.key
      )
    end
  end
  return tree
end

---The line of a node as `render` writes it after a change.
---@param node Tasks.LernNode
---@return string
local function line_of(node)
  local parts = { node.prefix, "[", node.mark, "] ", node.label }
  if node.promoted then
    parts[#parts + 1] = " " .. ARROW .. " " .. node.promoted
  end
  if node.reason then
    parts[#parts + 1] = " " .. EN_DASH .. " Grund: " .. node.reason
  end
  if node.key then
    parts[#parts + 1] = " {#" .. node.key .. "}"
  end
  parts[#parts + 1] = node.cr
  return table.concat(parts)
end

---The body text of a tree: the lines as they were, the changed nodes written anew.
---@param tree Tasks.LernTree
---@return string
function M.render(tree)
  local out = vim.list_slice(tree.lines, 1)
  for _, node in ipairs(tree.nodes) do
    if node.dirty then
      out[node.line] = line_of(node)
    end
  end
  return table.concat(out, "\n")
end

---Find a node by key, or by its position (`#3`, or the number 3).
---@param tree Tasks.LernTree
---@param ref string|integer
---@return Tasks.LernNode|nil
function M.node(tree, ref)
  if type(ref) == "number" then
    return tree.nodes[ref]
  end
  local n = tostring(ref):match("^#?(%d+)$")
  if n then
    return tree.nodes[tonumber(n)]
  end
  return tree.by_key[tostring(ref):gsub("^#", "")]
end

---Change the state of a leaf (and its reason). A parent has no mark of its own; seen and dropped need a reason; a
---reason on another state is dropped. The tree is derived anew; `render` writes the line.
---@param tree Tasks.LernTree
---@param ref string|integer
---@param state string
---@param reason? string
---@return Tasks.LernNode|nil node
---@return string|nil err
function M.set_state(tree, ref, state, reason)
  local node = M.node(tree, ref)
  if not node then
    return nil, "no such learning point: " .. tostring(ref)
  end
  if #node.children > 0 then
    return nil, "a learning point with children has no mark of its own: change its children"
  end
  if not M.MARK_OF[state] then
    return nil, "unknown state '" .. tostring(state) .. "' (open, learned, seen, dropped, blocked)"
  end
  reason = reason and trim(tostring(reason)) or nil
  if reason == "" then
    reason = nil
  end
  if reason and reason:find("[\r\n{}]") then
    return nil, "the reason must be one line without { }"
  end
  if M.NEEDS_REASON[state] and not (reason or node.reason) then
    return nil, state .. " needs a reason"
  end
  node.mark, node.state = M.MARK_OF[state], state
  if M.NEEDS_REASON[state] then
    node.reason = reason or node.reason
  else
    node.reason = reason
  end
  node.dirty = true
  tree.progress = zero()
  for _, root in ipairs(tree.roots) do
    derive(root)
    add_progress(tree.progress, root.progress)
  end
  return node, nil
end

---Write the note of a node: the `> ` lines below it (the blank lines between them included) give way to `text`, one
---`> ` line per line of the text, indented two columns deeper than the node; an empty text (or only white space)
---removes the note. Several lines are allowed, control characters are not (a tab is). Every other line stays byte for
---byte, a change made with `set_state` before included; the tree is parsed anew, since the lines after the note move.
---@param tree Tasks.LernTree
---@param ref string|integer
---@param text? string
---@return Tasks.LernNode|nil node
---@return string|nil err
function M.set_note(tree, ref, text)
  local node = M.node(tree, ref)
  if not node then
    return nil, "no such learning point: " .. tostring(ref)
  end
  text = (tostring(text or ""):gsub("\r\n", "\n"))
  if text:find("[%z\1-\8\11-\31\127]") or text:find("\194[\128-\159]") then
    return nil, "the note must be text without control characters"
  end
  if not text:match("%S") then
    text = ""
  end
  text = (text:gsub("%s+$", ""))
  local lines = vim.split(M.render(tree), "\n", { plain = true })
  -- the note as it stands: `> ` lines deeper than the node, blank lines between them; the next other line ends it
  local first, last
  local i = node.line + 1
  while lines[i] do
    local l = lines[i]:gsub("\r$", "")
    local nws = l:match("^(%s*)>")
    if nws and width(nws) > node.indent then
      first, last = first or i, i
    elseif l:match("%S") then
      break
    end
    i = i + 1
  end
  if first then
    for _ = first, last do
      table.remove(lines, first)
    end
  end
  local pad = node.prefix:match("^(%s*)") .. "  "
  local at = first or node.line + 1
  if text ~= "" then
    for k, l in ipairs(vim.split(text, "\n", { plain = true })) do
      local quoted = l == "" and ">" or ("> " .. l)
      table.insert(lines, at + k - 1, pad .. quoted .. node.cr)
    end
  end
  local fresh = M.parse(table.concat(lines, "\n"))
  for k in pairs(tree) do
    tree[k] = nil
  end
  for k, v in pairs(fresh) do
    tree[k] = v
  end
  return tree.nodes[node.index], nil
end

---Drop the first `w` columns of leading white space of a line (a tab counts 4, as `width` does).
---@param line string
---@param w integer
---@return string
local function dedent(line, w)
  local i, col = 1, 0
  while col < w do
    local c = line:sub(i, i)
    if c == " " then
      col = col + 1
    elseif c == "\t" then
      col = col + 4
    else
      break
    end
    i = i + 1
  end
  return line:sub(i)
end

---The lines a node's subtree spans: from its first child to the last line of its last descendant (a descendant's note
---and the lines between descendants included; blank lines at the end left out). nil for a node without children.
---@param tree Tasks.LernTree
---@param node Tasks.LernNode
---@return integer|nil first
---@return integer|nil last
function M.subtree_range(tree, node)
  if #node.children == 0 then
    return nil
  end
  local first = node.children[1].line
  -- the end: the line before the next node that is no descendant, or before the next heading, or the end of the text
  local stop = #tree.lines + 1
  for i = node.index + 1, #tree.nodes do
    local n = tree.nodes[i]
    if n.indent <= node.indent then
      stop = n.line
      break
    end
  end
  for i = first, stop - 1 do
    if (tree.lines[i] or ""):gsub("\r$", ""):match("^#+%s") then
      stop = i
      break
    end
  end
  local last = stop - 1
  while last > first and not (tree.lines[last] or ""):gsub("\r$", ""):match("%S") do
    last = last - 1
  end
  return first, last
end

---Promote a node: its subtree leaves the tree (returned as a `## Lernpunkte` body of its own, dedented to the root),
---its line gets the arrow to `id` and the mark `[ ]` (the state belongs to the task from now on), and the key `key`
---when it had none. Refused for a node that was promoted already and for a closed leaf (nothing left to learn).
---@param tree Tasks.LernTree
---@param ref string|integer
---@param id string
---@param key? string   # The key to write when the node has none.
---@return { body: string, subtree: string, node: Tasks.LernNode }|nil result
---@return string|nil err
function M.promote(tree, ref, id, key)
  local node = M.node(tree, ref)
  if not node then
    return nil, "no such learning point: " .. tostring(ref)
  end
  if node.promoted then
    return nil,
      ("learning point %s was promoted already (to %s)"):format(tostring(ref), node.promoted)
  end
  if #node.children == 0 and node.closed then
    return nil, ("learning point %s is closed already (%s)"):format(tostring(ref), node.state)
  end
  if not is_id(id) then
    return nil, "not an id <area>/<slug>: " .. tostring(id)
  end
  local sub = {}
  local first, last = M.subtree_range(tree, node)
  if first then
    local w = node.children[1].indent
    for i = first, last do
      sub[#sub + 1] = dedent((tree.lines[i] or ""):gsub("\r$", ""), w)
    end
  end
  node.promoted = id
  node.key = node.key or key
  node.mark, node.state, node.reason = " ", "open", nil
  node.dirty = true
  local lines = vim.split(M.render(tree), "\n", { plain = true })
  if first then
    for _ = first, last do
      table.remove(lines, first)
    end
  end
  return { body = table.concat(lines, "\n"), subtree = table.concat(sub, "\n"), node = node }, nil
end

---Take a promotion back: the arrow of the node goes, and `subtree` (a tree as a task keeps it in `## Lernpunkte`)
---comes back below the node and its note, indented one level deeper. The node's mark stays open.
---@param tree Tasks.LernTree
---@param ref string|integer
---@param subtree string
---@return string|nil body
---@return string|nil err
function M.unpromote(tree, ref, subtree)
  local node = M.node(tree, ref)
  if not node then
    return nil, "no such learning point: " .. tostring(ref)
  end
  if not node.promoted then
    return nil, ("learning point %s is not promoted"):format(tostring(ref))
  end
  node.promoted = nil
  node.dirty = true
  local lines = vim.split(M.render(tree), "\n", { plain = true })
  -- below the node's own note lines
  local at = node.line
  while true do
    local nxt = (lines[at + 1] or ""):gsub("\r$", "")
    local nws = nxt:match("^(%s*)>")
    if nws and width(nws) > node.indent then
      at = at + 1
    else
      break
    end
  end
  local pad = node.prefix:match("^(%s*)") .. "  "
  local add = {}
  for _, l in ipairs(vim.split(subtree or "", "\n", { plain = true })) do
    if l:match("%S") then
      add[#add + 1] = pad .. l .. node.cr
    elseif #add > 0 then
      add[#add + 1] = node.cr
    end
  end
  while #add > 0 and not add[#add]:match("%S") do
    table.remove(add)
  end
  for i, l in ipairs(add) do
    table.insert(lines, at + i, l)
  end
  return table.concat(lines, "\n"), nil
end

---The state a promoted task gives its learning point: open while it is open (`blocked` while it is blocked), and when
---it is finished the state of its outcome (none or `learned`: learned; `seen`: seen; `not-applicable`: dropped).
---@param task { status?: string, outcome?: string }
---@return string state
function M.state_of_task(task)
  if task.status == "done" then
    if task.outcome == "seen" then
      return "seen"
    elseif task.outcome == "not-applicable" then
      return "dropped"
    end
    return "learned"
  end
  return task.status == "blocked" and "blocked" or "open"
end

---"7 gelernt · 2 angeschaut · 1 entfällt · 3 offen": the progress in words (German, as the files are).
---@param p Tasks.LernProgress
---@return string
function M.progress_text(p)
  return ("%d gelernt \194\183 %d angeschaut \194\183 %d entf\195\164llt \194\183 %d offen"):format(
    p.learned,
    p.seen,
    p.dropped,
    p.open
  )
end

---The ids the arrows of a tree name, in document order, each once.
---@param tree Tasks.LernTree
---@return string[]
function M.promoted_ids(tree)
  local out, seen = {}, {}
  for _, node in ipairs(tree.nodes) do
    if node.promoted and not seen[node.promoted] then
      seen[node.promoted] = true
      out[#out + 1] = node.promoted
    end
  end
  return out
end

return M
