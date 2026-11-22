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
--- A node line reads `<label>[ → <id>][ – Grund: <reason>][ {xp=N}][ {h=N}][ {done_h=N}][ {for=t4}][ {optional}][ {machine=a,b}][ {safety}][ {#key}]`;
--- the marks in braces come last (in any order), the reason after the label (also `Reason:`, and `—` or `-` as the
--- dash), the arrow names the task the node was promoted to. An arrow is a reference only when an id `<area>/<slug>` follows it and nothing but the marks after
--- that; any other arrow (`Test rot → grün`) is text of the label. A `> ` line indented
--- below a node is its note. Every other line of the section (prose, blank lines, comments, code fences) is kept as it
--- is: `render` gives back the text byte for byte, only the nodes changed with `set_state` are written anew.
---
--- Machine (optional): `{machine=private}`, `{machine=workstation}`, `{machine=wsl}` (several with a comma) say where the point
--- may be practised; none means everywhere. A parent's mark holds for its subtree unless a child names its own. Safety:
--- `{safety}` marks a point where a mistake is dangerous; it holds for the subtree and `path` shows it first.
---
--- XP (optional): a leaf carries `{xp=N}` (a whole number, 0 to `MAX_XP`). Learned counts it in full, seen half
--- (rounded down), dropped leaves it out of the sum and the maximum (100 % stays reachable), open and blocked give 0.
--- A promoted leaf counts the `xp:` of its task when the caller gives it (`set_task_xp`), else its own. A parent sums
--- its children; an `{xp=N}` on a parent is a problem (`path-bad-xp`) and counts nothing. A tree without any XP works
--- as before (`has_xp = false`).
---
--- Hours (optional, for a path with a fixed rhythm, `tasks_nvim.path_schedule`): `{h=N}` or `{h=N-M}` the hours a
--- point is planned for, `{done_h=N}` the hours it took (`LP-10`); whole numbers or one decimal (`1.5`), up to
--- `MAX_HOURS`. Any node may carry them; nothing sums them up the tree. A value that is no such number is
--- `path-bad-hours`.
---
--- Evidence (optional, `tasks_nvim.learn`): `{for=t4}` / `{for=p3.5}` says for which stage of the competence scale a
--- point is evidence, `t` theory or `p` practice, a stage 0 to 8 in halves; anything else is `path-bad-for`.
---
--- Optional (`{optional}` on a node, mostly a group such as the books of a path): the node and its subtree count for
--- nothing that says how far the path is: `tree.progress` and `tree.xp` hold the other points only (progress, percent
--- levels and the path being finished), `tree.optional` holds the optional ones. Their XP still count once earned (an
--- XP level adds `tree.optional.xp.earned`, `lernlevel.evaluate`). A node keeps the progress of its whole subtree for
--- showing it; a parent is closed (and learned) when its points that are not optional are.
---
--- Pure Lua, no I/O. Not its job: whether an arrow names a task that exists, cycles over files, images on disk
--- (`check`); the path file itself (`tasks_nvim.paths`); levels and rewards (`tasks_nvim.lernlevel`).

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

---The largest XP of one point or task (a document must be able to carry every sum).
M.MAX_XP = 100000

---The XP a value stands for: a whole number from 0 to `MAX_XP` (a number or its digits), else nil.
---@param v any
---@return integer|nil
function M.to_xp(v)
  if type(v) == "number" then
    -- the range first: `%d` of a number beyond 2^63 has no meaning
    if v ~= v or v < 0 or v > M.MAX_XP or v ~= math.floor(v) then
      return nil
    end
    return v
  end
  if type(v) ~= "string" or not v:match("^%d+$") or #v > 6 then
    return nil
  end
  local n = tonumber(v)
  return (n and n <= M.MAX_XP) and n or nil
end

---The most hours one point may carry (planned or taken).
M.MAX_HOURS = 1000

---Hours as written in `{h=…}` / `{done_h=…}`: a whole number or one with one decimal (`1.5`, also `1,5`), 0 to
---`MAX_HOURS`; nil for anything else.
---@param v string
---@return number|nil
function M.to_hours(v)
  if type(v) ~= "string" then
    return nil
  end
  local t = v:gsub(",", ".")
  if not (t:match("^%d%d?%d?%d?$") or t:match("^%d%d?%d?%d?%.%d$")) then
    return nil
  end
  local n = tonumber(t)
  return (n and n <= M.MAX_HOURS) and n or nil
end

---The stage `{for=…}` names: the axis (`t` theory, `p` practice) and a stage 0 to 8 in halves (`t4`, `p3.5`,
---`P 3,5`); nil for anything else.
---@param v string
---@return "t"|"p"|nil axis
---@return number|nil level
function M.to_for(v)
  local axis, n = vim.trim(v or ""):lower():match("^([tp])%s*(%d[%.,]?%d?)$")
  if not axis then
    return nil
  end
  local level = tonumber((n:gsub(",", ".")))
  if not level or level > 8 or (level * 2) ~= math.floor(level * 2) then
    return nil
  end
  return axis, --[[@as "t"|"p"]]
    level == math.floor(level) and math.floor(level) or level
end

---The planned hours of `{h=…}`: `8` (8 to 8) or a span `8-10` (also with an en dash); nil when it is none.
---@param v string
---@return number|nil min
---@return number|nil max
function M.to_hours_span(v)
  local a, b = v:match("^%s*([%d.,]+)%s*%-%s*([%d.,]+)%s*$")
  if not a then
    a, b = v:match("^%s*([%d.,]+)%s*\226\128\147%s*([%d.,]+)%s*$")
  end
  if a then
    local lo, hi = M.to_hours(a), M.to_hours(b)
    if lo and hi and lo <= hi then
      return lo, hi
    end
    return nil
  end
  local n = M.to_hours(vim.trim(v))
  return n, n
end

---The XP a suggestion gives per effort size.
M.XP_OF_EFFORT = { XS = 10, S = 25, M = 50, L = 100, XL = 200 }

---A suggestion of XP for a form to fill in beforehand (never stored, never a scheme in the file): from the effort of
---a task or point when it has one (`XS` 10 … `XL` 200, days ×50, at least 5), else from the depth of a point (a
---root 20, one level down 15, deeper 10).
---@param subject { effort?: string, depth?: integer }
---@return integer
function M.suggest_xp(subject)
  local effort = subject and subject.effort
  if type(effort) == "string" then
    if M.XP_OF_EFFORT[effort] then
      return M.XP_OF_EFFORT[effort]
    end
    local days = tonumber(effort:match("^(%d*%.?%d+)d$") or "")
    if days then
      return math.min(M.MAX_XP, math.max(5, math.floor(days * 50 + 0.5)))
    end
  end
  local depth = subject and subject.depth or 0
  return depth <= 0 and 20 or depth == 1 and 15 or 10
end

---The share of its XP a leaf earns in a state: learned 1, seen one half, the rest 0; dropped counts nowhere.
---@param state string
---@param xp integer
---@return integer
function M.earned_xp(state, xp)
  if state == "learned" then
    return xp
  elseif state == "seen" then
    return math.floor(xp / 2)
  end
  return 0
end

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
---@field xp? integer            # The XP the leaf counts: its task's (`set_task_xp`), else its own; nil: none.
---@field xp_own? integer        # The `{xp=N}` of its line.
---@field xp_raw? string         # The text of an `{xp=…}` that is no XP (kept as written).
---@field xp_from? "point"|"task"
---@field xp_progress Tasks.LernXp
---@field h_raw? string          # The text of `{h=…}` as written.
---@field h_min? number          # Planned hours (`{h=8}`: 8, `{h=8-10}`: 8); nil without or when it is no number.
---@field h_max? number
---@field done_h_raw? string     # The text of `{done_h=…}` as written.
---@field done_h? number         # The hours it took.
---@field for_raw? string        # The text of `{for=…}` as written.
---@field for_axis? "t"|"p"      # The axis `{for=…}` names (theory, practice); nil without or when it is none.
---@field for_level? number      # The stage it names, 0..8 in halves.
---@field optional? boolean      # `{optional}` on its own line.
---@field safety? boolean        # `{safety}`: a danger the reader must have read; holds for the subtree.
---@field machine_raw? string    # The text of `{machine=…}` as written.
---@field machine? string[]      # Its machines (`private`, `workstation`, `wsl`); nil: no mark or a bad one.
---@field machine_eff? string[]  # The machines that count for it: its own, else the nearest parent's; nil: every machine.
---@field safety_eff? Tasks.LernNode  # The node whose `{safety}` holds for it (itself or the nearest parent); nil: none.
---@field in_optional boolean     # It, or a node above it, is optional.
---@field opt_progress Tasks.LernProgress  # The part of `progress` that is optional.
---@field opt_xp Tasks.LernXp              # The part of `xp_progress` that is optional.
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

---@class Tasks.LernXp
---@field earned integer         # Learned in full, seen half (rounded down).
---@field possible integer       # Every leaf but the dropped ones.
---@field open integer           # The XP of the open and blocked leaves.
---@field points integer         # Leaves (not dropped) that carry XP.
---@field missing integer        # Leaves (not dropped) without XP.

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
---@field xp Tasks.LernXp
---@field has_xp boolean          # Some leaf carries XP (an optional one too).
---@field optional { progress: Tasks.LernProgress, xp: Tasks.LernXp }  # The optional points, apart.
---@field has_optional boolean    # Some node is optional.
---@field problems Tasks.LernProblem[]
---@field hints Tasks.LernProblem[]   # Worth a word, never a fault: an arrow before a word that looks like an id but is none.
---@field stray Tasks.LernStray[]   # Lines of the section that are no point, no note below one and not empty (`path-stray-line`).
---@field lines string[]           # The body split at `\n` (a CR stays on its line).

---@class Tasks.LernStray
---@field line integer
---@field text string
---@field marks string[]           # The marks on the line (`{xp=…}`, `{#…}`): they count for nothing there.

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

---The start of the paragraph below the literature that names the books missing from the stock (LP-11): text, no
---stray line.
M.SHELF_STARTS = { "Fehlt im Bestand", "Missing from the stock" }

---@param line string
---@return boolean
local function is_shelf_line(line)
  local text = line:gsub("^%s+", "")
  for _, s in ipairs(M.SHELF_STARTS) do
    if text:sub(1, #s) == s then
      return true
    end
  end
  return false
end

---The machines a `{machine=…}` mark may name (`MASCHINE-01`: `workstation`, `private` is the rest, `wsl` a shell in it).
M.MACHINES = { "private", "workstation", "wsl" }

---Split the value of `{machine=a,b}` into its machines; nil when it is empty or names an unknown one.
---@param raw string
---@return string[]|nil
function M.to_machines(raw)
  local out, seen = {}, {}
  for part in (raw .. ","):gmatch("([^,]*),") do
    part = trim(part):lower()
    if not vim.tbl_contains(M.MACHINES, part) then
      return nil
    end
    if not seen[part] then
      seen[part] = true
      out[#out + 1] = part
    end
  end
  return #out > 0 and out or nil
end

---Whether a node may be practised on a machine (`private`, `workstation`, `wsl`): it carries no `{machine=…}` (its own
---or a parent's) or the machine is among them. The private machine also has WSL, so a `wsl` point goes there too; the
---workstation does not, and `wsl` itself stays strict (only points that name it).
---@param node Tasks.LernNode
---@param machine string
---@return boolean
function M.on_machine(node, machine)
  local eff = node.machine_eff
  if eff == nil or vim.tbl_contains(eff, machine) then
    return true
  end
  return machine == "private" and vim.tbl_contains(eff, "wsl")
end

---The refusal for closing a point under a `{safety}` mark without the reader's ack (`danger` is the node that
---carries the mark).
---@param danger Tasks.LernNode
---@return string
function M.safety_message(danger)
  return ("the point is under a {safety} mark (line %d: %s): read it and close it with ack (--ack, ack: true)"):format(
    danger.line,
    danger.label
  )
end

---The role a machine name stands for: `workstation` and `wsl` as they are, an empty name or `default` the private
---machine; nil for any other value.
---@param role? string
---@return string|nil
function M.machine_of_role(role)
  role = trim((role or ""):lower())
  if role == "" or role == "default" then
    return "private"
  end
  return vim.tbl_contains(M.MACHINES, role) and role or nil
end

---The marks `{xp=…}` and `{#…}` on a line, as written.
---@param line string
---@return string[]
local function stray_marks(line)
  local out = {}
  for m in line:gmatch("{xp=[^{}]*}") do
    out[#out + 1] = m
  end
  for m in line:gmatch("{#[^{}%s]+}") do
    out[#out + 1] = m
  end
  return out
end

---Split the text after the mark into label, arrow, reason and key.
---@param text string
---@return { label: string, safety?: boolean, machine_raw?: string, key?: string, xp?: integer, xp_raw?: string, h_raw?: string, done_h_raw?: string, for_raw?: string, optional?: boolean, reason?: string, promoted?: string, arrow_bad?: string }
function M.split(text)
  local rest = text:gsub("%s+$", "")
  local out = {}
  -- the key, the XP, the hours and the optional mark at the end, in any order, each once
  for _ = 1, 8 do
    local before, key = rest:match("^(.-)%s*{#([^{}%s]+)}$")
    local b8, fr = rest:match("^(.-)%s*{for=([^{}]*)}$")
    local b6, mach = rest:match("^(.-)%s*{machine=([^{}]*)}$")
    local b7 = rest:match("^(.-)%s*{safety}$")
    local b3 = rest:match("^(.-)%s*{optional}$")
    local b4, h = rest:match("^(.-)%s*{h=([^{}]*)}$")
    local b5, dh = rest:match("^(.-)%s*{done_h=([^{}]*)}$")
    if before and not out.key then
      rest, out.key = before, key
    elseif b3 and not out.optional then
      rest, out.optional = b3, true
    elseif b6 and not out.machine_raw then
      rest, out.machine_raw = b6, mach
    elseif b7 and not out.safety then
      rest, out.safety = b7, true
    elseif b4 and not out.h_raw then
      rest, out.h_raw = b4, h
    elseif b5 and not out.done_h_raw then
      rest, out.done_h_raw = b5, dh
    elseif b8 and not out.for_raw then
      rest, out.for_raw = b8, fr
    else
      local b2, raw = rest:match("^(.-)%s*{xp=([^{}]*)}$")
      if b2 and out.xp == nil and out.xp_raw == nil then
        rest = b2
        out.xp = M.to_xp(raw)
        if out.xp == nil then
          out.xp_raw = raw
        end
      end
    end
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
  -- an arrow is a reference only when an id `<area>/<slug>` follows it and nothing but the marks after that (key, XP
  -- and reason were taken off above): "Test rot → grün" and "Klick → Route" are text. A `→` before a word that has the
  -- form of an id but is none (`area/Slug`) stays text as well, and is named (`arrow_bad`, a hint of `check`).
  for _, arrow in ipairs({ ARROW, "->" }) do
    local head, target = rest:match("^(.-)%s+" .. arrow:gsub("%-", "%%-") .. "%s*(%S*)$")
    if head and is_id(target) then
      out.promoted = target
      rest = head
      break
    elseif head and arrow == ARROW and target:match("^[^/%s]+/[^/%s]+$") then
      out.arrow_bad = target
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

---@return Tasks.LernXp
local function zero_xp()
  return { earned = 0, possible = 0, open = 0, points = 0, missing = 0 }
end

---@param into table<string, integer>
---@param from table<string, integer>
local function add_progress(into, from)
  for k, v in pairs(from) do
    into[k] = into[k] + v
  end
end

---@param into table<string, integer>
---@param from table<string, integer>
---@param minus table<string, integer>
local function add_difference(into, from, minus)
  for k, v in pairs(from) do
    into[k] = into[k] + v - minus[k]
  end
end

---Derive state, closedness and progress of a node from its leaves (recursive).
---@param node Tasks.LernNode
---@param in_optional? boolean  # A node above it is optional.
local function derive(node, in_optional)
  local p = zero()
  local x = zero_xp()
  local op, ox = zero(), zero_xp()
  node.in_optional = in_optional == true or node.optional == true
  if #node.children == 0 then
    local s = node.state or "open"
    p.total = 1
    if s ~= "dropped" then
      if node.xp then
        x.points, x.possible = 1, node.xp
        x.earned = M.earned_xp(s, node.xp)
        if not CLOSED[s] then
          x.open = node.xp
        end
      else
        x.missing = 1
      end
    end
    if s == "blocked" then
      p.open, p.blocked = 1, 1
    elseif CLOSED[s] then
      p[s] = 1
    else
      p.open = 1
    end
    node.derived = node.state or "open"
    node.closed = CLOSED[s] == true
    if node.in_optional then
      add_progress(op, p)
      add_progress(ox, x)
    end
  else
    for _, c in ipairs(node.children) do
      derive(c, node.in_optional)
      add_progress(p, c.progress)
      add_progress(x, c.xp_progress)
      add_progress(op, c.opt_progress)
      add_progress(ox, c.opt_xp)
    end
    -- closed and learned by the points that are not optional; a subtree of optional points only by its own
    local r = p
    if op.total < p.total then
      r = zero()
      add_difference(r, p, op)
    end
    node.closed = r.open == 0
    if r.learned == r.total then
      node.derived = "learned"
    elseif r.learned + r.seen + r.dropped == 0 then
      node.derived = "open"
    else
      node.derived = "partial"
    end
  end
  node.progress = p
  node.xp_progress = x
  node.opt_progress = op
  node.opt_xp = ox
end

---Derive every root anew and sum the tree's progress and XP.
---@param tree Tasks.LernTree
local function derive_tree(tree)
  tree.progress, tree.xp = zero(), zero_xp()
  tree.optional = { progress = zero(), xp = zero_xp() }
  for _, root in ipairs(tree.roots) do
    derive(root)
    add_difference(tree.progress, root.progress, root.opt_progress)
    add_difference(tree.xp, root.xp_progress, root.opt_xp)
    add_progress(tree.optional.progress, root.opt_progress)
    add_progress(tree.optional.xp, root.opt_xp)
  end
  tree.has_xp = tree.xp.points + tree.optional.xp.points > 0
  tree.has_optional = false
  for _, node in ipairs(tree.nodes) do
    if node.optional then
      tree.has_optional = true
      break
    end
  end
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
    xp = zero_xp(),
    has_xp = false,
    optional = { progress = zero(), xp = zero_xp() },
    has_optional = false,
    problems = {},
    hints = {},
    stray = {},
    lines = lines,
  }
  local function problem(code, line, msg, key)
    tree.problems[#tree.problems + 1] = { code = code, line = line, key = key, message = msg }
  end
  local inside, fence = false, nil
  local stack = {}
  local last
  -- a line of the section that is no point, no note below one and not empty is lost to the tree (`stray`); comments,
  -- sub-headings and the paragraph `Fehlt im Bestand: …` that LP-11 asks for below the literature are text on purpose
  local comment, shelf = false, false
  local function stray_line(i, line)
    if comment then
      comment = not line:find("-->", 1, true)
      return
    end
    local open = line:match("^%s*<!%-%-()")
    if open then
      comment = not line:find("-->", open, true)
      return
    end
    if line:match("^###") then
      return
    end
    if shelf or is_shelf_line(line) then
      shelf = true
      return
    end
    tree.stray[#tree.stray + 1] = { line = i, text = line, marks = stray_marks(line) }
  end
  for i, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    if not line:match("%S") then
      shelf = false
    end
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
            xp = parts.xp,
            xp_own = parts.xp,
            xp_raw = parts.xp_raw,
            xp_from = parts.xp and "point" or nil,
            xp_progress = zero_xp(),
            optional = parts.optional,
            safety = parts.safety,
            machine_raw = parts.machine_raw,
            machine = parts.machine_raw and M.to_machines(parts.machine_raw) or nil,
            h_raw = parts.h_raw,
            done_h_raw = parts.done_h_raw,
            for_raw = parts.for_raw,
            in_optional = false,
            opt_progress = zero(),
            opt_xp = zero_xp(),
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
          if parts.xp_raw then
            problem(
              "path-bad-xp",
              i,
              ("{xp=%s} is no XP (a whole number from 0 to %d)"):format(parts.xp_raw, M.MAX_XP),
              parts.key
            )
          end
          if parts.h_raw then
            node.h_min, node.h_max = M.to_hours_span(parts.h_raw)
            if not node.h_min then
              problem(
                "path-bad-hours",
                i,
                ("{h=%s} is no hours (8, 1.5 or a span 8-10, up to %d)"):format(
                  parts.h_raw,
                  M.MAX_HOURS
                ),
                parts.key
              )
            end
          end
          if parts.done_h_raw then
            node.done_h = M.to_hours(vim.trim(parts.done_h_raw))
            if not node.done_h then
              problem(
                "path-bad-hours",
                i,
                ("{done_h=%s} is no hours (8 or 1.5, up to %d)"):format(
                  parts.done_h_raw,
                  M.MAX_HOURS
                ),
                parts.key
              )
            end
          end
          if parts.for_raw then
            node.for_axis, node.for_level = M.to_for(parts.for_raw)
            if not node.for_axis then
              problem(
                "path-bad-for",
                i,
                ("{for=%s} names no stage (t or p and a stage 0 to 8 in halves: t4, p3.5)"):format(
                  parts.for_raw
                ),
                parts.key
              )
            end
          end
          if parts.arrow_bad then
            -- a hint, not a problem: the arrow is read as text
            tree.hints[#tree.hints + 1] = {
              code = "path-bad-arrow",
              line = i,
              key = parts.key,
              message = ("the arrow is text: '%s' has the form of an id <area>/<slug> but is none"):format(
                parts.arrow_bad
              ),
            }
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
            stray_line(i, line)
          end
        end
      end
    end
  end
  -- a parent sums its children: XP of its own count nothing
  for _, node in ipairs(tree.nodes) do
    if #node.children > 0 and (node.xp_own or node.xp_raw) then
      node.xp, node.xp_from = nil, nil
      problem(
        "path-bad-xp",
        node.line,
        "a learning point with children sums the XP of its children: put {xp=…} on them",
        node.key
      )
    end
  end
  M.mark_inherited(tree)
  derive_tree(tree)
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

---Resolve `{machine=…}` and `{safety}` down the tree (a parent's mark holds for the subtree unless a child names its
---own machines) and name the faults of the marks (`path-bad-machine`; the hint `path-safety-unmarked`).
---@param tree Tasks.LernTree
function M.mark_inherited(tree)
  for _, node in ipairs(tree.nodes) do
    local parent = node.parent
    node.machine_eff = node.machine or (parent and parent.machine_eff) or nil
    node.safety_eff = node.safety and node or (parent and parent.safety_eff) or nil
    if node.machine_raw and not node.machine then
      tree.problems[#tree.problems + 1] = {
        code = "path-bad-machine",
        line = node.line,
        key = node.key,
        message = ("{machine=%s} names no machine (%s, several with a comma)"):format(
          node.machine_raw,
          table.concat(M.MACHINES, ", ")
        ),
      }
    end
    -- a hint, never a warning: only a text that starts with `Sicherheit:` (the convention for a danger) is named, since
    -- the word alone also stands for IT security
    if not node.safety_eff and node.label:match("^%s*Sicherheit%s*:") then
      tree.hints[#tree.hints + 1] = {
        code = "path-safety-unmarked",
        line = node.line,
        key = node.key,
        message = "the text starts with 'Sicherheit:' but the point has no {safety} mark (nor a parent with one); mark it if it is a danger",
      }
    end
  end
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
  if node.xp_own then
    parts[#parts + 1] = " {xp=" .. node.xp_own .. "}"
  elseif node.xp_raw then
    parts[#parts + 1] = " {xp=" .. node.xp_raw .. "}"
  end
  if node.h_raw then
    parts[#parts + 1] = " {h=" .. node.h_raw .. "}"
  end
  if node.done_h_raw then
    parts[#parts + 1] = " {done_h=" .. node.done_h_raw .. "}"
  end
  if node.for_raw then
    parts[#parts + 1] = " {for=" .. node.for_raw .. "}"
  end
  if node.optional then
    parts[#parts + 1] = " {optional}"
  end
  if node.machine_raw then
    parts[#parts + 1] = " {machine=" .. node.machine_raw .. "}"
  end
  if node.safety then
    parts[#parts + 1] = " {safety}"
  end
  if node.key then
    parts[#parts + 1] = " {#" .. node.key .. "}"
  end
  parts[#parts + 1] = node.cr
  return table.concat(parts)
end

---Give the promoted leaves the XP of their tasks: `xp_of[id]` is the `xp:` of the task an arrow names (nil: the task
---has none, the leaf keeps its own `{xp=N}`). The tree is derived anew; nothing is written.
---@param tree Tasks.LernTree
---@param xp_of table<string, integer|false>
function M.set_task_xp(tree, xp_of)
  for _, node in ipairs(tree.nodes) do
    if #node.children == 0 and node.promoted then
      local x = xp_of[node.promoted]
      if x then
        node.xp, node.xp_from = x, "task"
      else
        node.xp, node.xp_from = node.xp_own, node.xp_own and "point" or nil
      end
    end
  end
  derive_tree(tree)
end

---Change the XP of a leaf: a whole number writes `{xp=N}` into its line, nil (or "") removes it. A parent sums its
---children and has none of its own. The tree is derived anew; `render` writes the line.
---@param tree Tasks.LernTree
---@param ref string|integer
---@param xp integer|string|nil
---@return Tasks.LernNode|nil node
---@return string|nil err
function M.set_xp(tree, ref, xp)
  local node = M.node(tree, ref)
  if not node then
    return nil, "no such learning point: " .. tostring(ref)
  end
  if #node.children > 0 then
    return nil, "a learning point with children sums the XP of its children: change theirs"
  end
  local n
  if xp ~= nil and xp ~= "" then
    n = M.to_xp(xp)
    if not n then
      return nil, ("xp must be a whole number from 0 to %d, got %s"):format(M.MAX_XP, tostring(xp))
    end
  end
  node.xp_own, node.xp_raw = n, nil
  if node.xp_from ~= "task" then
    node.xp, node.xp_from = n, n and "point" or nil
  end
  node.dirty = true
  derive_tree(tree)
  return node, nil
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
  derive_tree(tree)
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
