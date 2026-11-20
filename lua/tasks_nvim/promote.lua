---@module 'tasks_nvim.promote'
---@brief Promote a learning point to a task of its own, and take the promotion back.
---@description
--- A learning point (a node of the tree in `## Lernpunkte`, of a learning path or of a task) becomes a task:
---
---   - the task (`kind: task`, `category: [learning]`, `point: <container>#<key>`) is made in the container's area or
---     the one asked for; the node's subtree moves into the task's own `## Lernpunkte`, so the task can promote again
---     (the recursion: Lua lernen -> C-Compiler -> Sprache C);
---   - the node's line gets the arrow `→ <task id>` and the mark `[ ]`, and a key when it had none. From now on the
---     state of the node belongs to the task: `done_flow` writes it when the task is finished (`lernbaum.state_of_task`:
---     learned, seen or dropped after the task's `outcome`), `check` names a node whose mark says otherwise.
---
--- `unpromote` is the way back while the task holds no work of its own: open (not doing, blocked, parked), no commits,
--- no folder (no assets). The task's `## Lernpunkte` (as it is now: points ticked meanwhile come along) goes back
--- below the node, the arrow goes, the task file is removed. Both take `dry_run`; `promote` answers its `inverse`.
---
--- The container is written under its lock and checked against `if_match`; the task is made first and removed again
--- when the container cannot be written.

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local lernbaum = require("tasks_nvim.lernbaum")
local model = require("tasks_nvim.model")
local mutate = require("tasks_nvim.mutate")
local paths = require("tasks_nvim.paths")
local vault = require("tasks_nvim.vault")

local M = {}

---The heading a task's tree stands under.
local SECTION = "Lernpunkte"

---The promoted points below `node` (its descendants with an arrow and a key): their tasks name the container in
---`point:`, which changes when the subtree moves.
---@param node Tasks.LernNode
---@return { id: string, key: string }[]
local function promoted_below(node)
  local out = {}
  local function walk(n)
    for _, child in ipairs(n.children) do
      if child.promoted and child.key then
        out[#out + 1] = { id = child.promoted, key = child.key }
      end
      walk(child)
    end
  end
  walk(node)
  return out
end

---Point the open tasks of `list` at their point's new container. A finished task keeps its file as it is (`check`
---names its `point:` then). Answers the ids changed.
---@param list { id: string, key: string }[]
---@param container string
---@param root string
---@param today string
---@return string[]
local function repoint(list, container, root, today)
  local changed = {}
  for _, e in ipairs(list) do
    local t = mutate.find_open(e.id, root)
    if t then
      local ok = mutate.set(
        e.id,
        { point = container .. "#" .. e.key },
        { root = root, today = today, index = false }
      )
      if ok then
        changed[#changed + 1] = e.id
      end
    end
  end
  return changed
end

---The container of a learning point: an open path or an open task, with its file.
---@param id string
---@param root string
---@return { id: string, area: string, kind: "path"|"task", path: string, folder: boolean }|nil
---@return string|nil err
local function container_of(id, root)
  local p = paths.find(id, { root = root })
  if p and not (p.errors and #p.errors > 0 and not p.title) then
    return { id = p.id, area = p.area, kind = "path", path = p.path, folder = p.folder == true },
      nil
  end
  local t = mutate.find_open(id, root)
  if t then
    return { id = t.id, area = t.area, kind = "task", path = t.path, folder = t.folder == true },
      nil
  end
  return nil, "no open learning path or task: " .. tostring(id)
end

---Split a file text into the part before the body (frontmatter) and the body, as `paths.point` does.
---@param text string
---@param path string
---@return string|nil head
---@return string|nil body
---@return string|nil err
local function split_body(text, path)
  local parsed = fm.parse(text)
  if not (parsed and parsed.has_block) then
    return nil, nil, path .. " has no readable frontmatter"
  end
  local body = parsed.body or ""
  if #body > 0 and text:sub(-#body) ~= body then
    return nil, nil, "cannot place the body of " .. path
  end
  return text:sub(1, #text - #body), body, nil
end

---The text of a label without its Markdown: `[text](url)` -> text, images dropped, white space squeezed.
---@param label string
---@return string
function M.plain_label(label)
  local s = label:gsub("!%[[^%]]*%]%([^%)]*%)", "")
  s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
  s = s:gsub("`", "")
  return vim.trim((s:gsub("%s+", " ")))
end

---A key that is free in the tree, from a title.
---@param tree Tasks.LernTree
---@param title string
---@return string
local function free_key(tree, title)
  local base = mutate.slugify(title):sub(1, 48):gsub("%-+$", "")
  if base == "" or not lernbaum.valid_key(base) then
    base = "punkt"
  end
  local key, n = base, 1
  while tree.by_key[key] do
    n = n + 1
    key = base .. "-" .. n
  end
  return key
end

---The body of the new task.
---@param container string
---@param key string
---@param node Tasks.LernNode
---@param subtree string
---@return string
local function task_body(container, key, node, subtree)
  local lines = {
    "## Kontext",
    "",
    ("Befördert aus dem Lernpunkt `{#%s}` von `%s`."):format(key, container),
  }
  if node.link then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Quelle: <" .. node.link .. ">"
  end
  if node.note then
    lines[#lines + 1] = ""
    for _, l in ipairs(vim.split(node.note, "\n", { plain = true })) do
      lines[#lines + 1] = "> " .. l
    end
  end
  vim.list_extend(lines, { "", "## " .. SECTION, "" })
  if subtree ~= "" then
    lines[#lines + 1] = subtree
  else
    lines[#lines + 1] =
      "<!-- Lernpunkte dieses Themas, je `- [ ] …`; befördern geht auch hier. -->"
  end
  vim.list_extend(lines, {
    "",
    "## Akzeptanz",
    "",
    "- [ ] Alle Lernpunkte abgeschlossen",
    "",
    "## Notizen",
    "",
  })
  return table.concat(lines, "\n")
end

---@class Tasks.PromoteOpts
---@field root? string
---@field area? string        # The area of the new task (default: the container's).
---@field title? string       # Default: the node's label without its Markdown.
---@field actor? string
---@field today? string
---@field if_match? string    # The `etag` of the container file the caller read.
---@field dry_run? boolean    # Nothing is written; the result says what would be.
---@field index? boolean      # Regenerate the area indexes (default true).

---Promote the learning point `ref` (a key or `#n`) of the path or task `container` to a task.
---@param container string
---@param ref string|integer
---@param opts? Tasks.PromoteOpts
---@return { id: string, path?: string, container: string, key: string, point: string, moved: integer, repointed?: string[], dry_run?: boolean, inverse: { op: string, container: string, key: string } }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict" }`
function M.promote(container, ref, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local c, cerr = container_of(container, root)
  if not c then
    return nil, cerr, { code = "not_found" }
  end
  local area = opts.area or c.area
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area), { code = "invalid_argument" }
  end
  local today = opts.today or model.today()

  local result
  local ok, werr, winfo = fsio.with_lock(c.path, function()
    local cur, rd_err = fsio.read(c.path)
    if not cur then
      return nil, "cannot read " .. c.path .. ": " .. tostring(rd_err)
    end
    local etag = fsio.etag(cur)
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on (it is %s, not %s)"):format(
          c.id,
          etag,
          tostring(opts.if_match)
        ),
        { code = "conflict", id = c.id, expected = opts.if_match, actual = etag }
    end
    local head, body, berr = split_body(cur, c.path)
    if not head then
      return nil, berr, { code = "invalid_argument" }
    end
    local tree = lernbaum.parse(body)
    local node = lernbaum.node(tree, ref)
    if not node then
      return nil, ("no learning point %s in %s"):format(tostring(ref), c.id), { code = "not_found" }
    end
    local title = opts.title or M.plain_label(node.label)
    if title == "" then
      return nil,
        "the learning point has no text to name the task by: give a title",
        { code = "invalid_argument" }
    end
    local key = node.key or free_key(tree, title)
    local point = c.id .. "#" .. key
    -- the id first (a dry run of `new`): the arrow names it
    local probe, perr =
      mutate.new(area, { root = root, title = title, today = today, dry_run = true })
    if not probe then
      return nil, perr, { code = "invalid_argument" }
    end
    local below = promoted_below(node)
    local moved, merr = lernbaum.promote(tree, node.index, probe.id, key)
    if not moved then
      return nil, merr, { code = "invalid_argument" }
    end
    local new_opts = {
      root = root,
      title = title,
      kind = "task",
      category = "learning",
      actor = opts.actor,
      point = point,
      -- the XP of the point go along: the task counts them from now on
      xp = node.xp_own,
      today = today,
      slug = probe.slug,
      body = task_body(c.id, key, node, moved.subtree),
      index = false,
    }
    local n_moved = 0
    for _ in moved.subtree:gmatch("[^\n]+") do
      n_moved = n_moved + 1
    end
    result = {
      id = probe.id,
      container = c.id,
      key = key,
      point = point,
      moved = n_moved,
      inverse = { op = "unpromote", container = c.id, key = key },
    }
    if opts.dry_run then
      result.dry_run = true
      return true
    end
    local made, nerr = mutate.new(area, new_opts)
    if not made then
      return nil, nerr
    end
    if made.id ~= probe.id then
      -- somebody took the slug between the two calls: the arrow would name the wrong task
      os.remove(made.path)
      return nil, "the id " .. probe.id .. " was taken meanwhile; try again", { code = "conflict" }
    end
    result.path = made.path
    -- the points promoted below the moved one live in the new task now
    result.repointed = repoint(below, made.id, root, today)
    local text = head .. moved.body
    text = fm.update_text(text, { { "updated", today } }) or text
    local wrote, wr_err = fsio.write_atomic(c.path, text)
    if not wrote then
      os.remove(made.path)
      return nil, "cannot write " .. c.path .. ": " .. tostring(wr_err)
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  if not opts.dry_run and opts.index ~= false then
    local areas = { [area] = true, [c.area] = true }
    for a in pairs(areas) do
      index.write_area(a, { root = root })
    end
  end
  return result, nil
end

---The lines of the `## Lernpunkte` section of a body (without the heading; blank lines at both ends dropped).
---@param body string
---@return string
local function section_text(body)
  local lines = vim.split(body, "\n", { plain = true })
  local out, inside = {}, false
  for _, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    local hashes, name = line:match("^(#+)%s+(.-)%s*$")
    if hashes and #hashes <= 2 then
      inside = #hashes == 2 and vim.tbl_contains(lernbaum.HEADINGS, name)
    elseif inside and not line:match("^%s*<!%-%-.*%-%->%s*$") then
      out[#out + 1] = line
    end
  end
  while #out > 0 and not out[1]:match("%S") do
    table.remove(out, 1)
  end
  while #out > 0 and not out[#out]:match("%S") do
    table.remove(out)
  end
  return table.concat(out, "\n")
end

---Take back the promotion of the learning point `ref` of `container`: its task's tree comes back below the node, the
---arrow goes, the task file is removed. Refused when the task holds work of its own (not open, commits, a folder).
---@param container string
---@param ref string|integer
---@param opts? { root?: string, today?: string, if_match?: string, dry_run?: boolean, index?: boolean }
---@return { id: string, container: string, key?: string, dry_run?: boolean }|nil result
---@return string|nil err
---@return table|nil info
function M.unpromote(container, ref, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local c, cerr = container_of(container, root)
  if not c then
    return nil, cerr, { code = "not_found" }
  end
  local today = opts.today or model.today()
  local result
  local ok, werr, winfo = fsio.with_lock(c.path, function()
    local cur, rd_err = fsio.read(c.path)
    if not cur then
      return nil, "cannot read " .. c.path .. ": " .. tostring(rd_err)
    end
    local etag = fsio.etag(cur)
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on (it is %s, not %s)"):format(
          c.id,
          etag,
          tostring(opts.if_match)
        ),
        { code = "conflict", id = c.id, expected = opts.if_match, actual = etag }
    end
    local head, body, berr = split_body(cur, c.path)
    if not head then
      return nil, berr, { code = "invalid_argument" }
    end
    local tree = lernbaum.parse(body)
    local node = lernbaum.node(tree, ref)
    if not node then
      return nil, ("no learning point %s in %s"):format(tostring(ref), c.id), { code = "not_found" }
    end
    if not node.promoted then
      return nil,
        ("learning point %s of %s is not promoted"):format(tostring(ref), c.id),
        { code = "invalid_argument" }
    end
    local task = mutate.find_open(node.promoted, root)
    if not task then
      return nil,
        node.promoted .. " is not open (finished or gone): its work stays where it is",
        { code = "invalid_argument" }
    end
    if task.status ~= "open" then
      return nil,
        ("%s is %s: it holds work of its own, take it back by hand"):format(task.id, task.status),
        { code = "invalid_argument" }
    end
    if #(task.commits or {}) > 0 or task.folder then
      return nil,
        task.id .. " has commits or assets of its own: take it back by hand",
        { code = "invalid_argument" }
    end
    if task.point and task.point ~= c.id .. "#" .. (node.key or "") then
      return nil,
        ("%s was promoted from %s, not from this point"):format(task.id, task.point),
        { code = "invalid_argument" }
    end
    local ttext, terr = fsio.read(task.path)
    if not ttext then
      return nil, "cannot read " .. task.path .. ": " .. tostring(terr)
    end
    local _, tbody = split_body(ttext, task.path)
    local back, uerr = lernbaum.unpromote(tree, node.index, section_text(tbody or ""))
    -- the points the task promoted itself go back with its tree: their tasks name the container again
    local below = {}
    do
      local ttree = lernbaum.parse(tbody or "")
      for _, n in ipairs(ttree.nodes) do
        if n.promoted and n.key then
          below[#below + 1] = { id = n.promoted, key = n.key }
        end
      end
    end
    if not back then
      return nil, uerr, { code = "invalid_argument" }
    end
    result = { id = task.id, container = c.id, key = node.key }
    if opts.dry_run then
      result.dry_run = true
      return true
    end
    local text = head .. back
    text = fm.update_text(text, { { "updated", today } }) or text
    local wrote, wr_err = fsio.write_atomic(c.path, text)
    if not wrote then
      return nil, "cannot write " .. c.path .. ": " .. tostring(wr_err)
    end
    local removed, rm_err = os.remove(task.path)
    if not removed then
      -- the tree is back in the container: put the old text back so nothing is there twice
      fsio.write_atomic(c.path, cur)
      return nil, "cannot remove " .. task.path .. ": " .. tostring(rm_err)
    end
    result.area = task.area
    result.repointed = repoint(below, c.id, root, today)
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  if not opts.dry_run and opts.index ~= false then
    local areas = { [c.area] = true, [result.area or c.area] = true }
    for a in pairs(areas) do
      index.write_area(a, { root = root })
    end
  end
  return result, nil
end

---Write the state a finished (or reopened) task gives its learning point into the container, when the task names one
---(`point:`) and the node's mark says something else. Never raises; a missing container or node is no error here
---(`check` names it).
---@param task { id: string, point?: string, status?: string, outcome?: string, outcome_reason?: string }
---@param opts? { root?: string, today?: string }
---@return { container: string, key: string, state: string, changed: boolean }|nil result
---@return string|nil err
function M.sync_point(task, opts)
  opts = opts or {}
  if not task.point then
    return nil
  end
  local cid, key = model.parse_point(task.point)
  if not cid then
    return nil
  end
  local root = vault.root(opts)
  if not root then
    return nil
  end
  local c = container_of(cid, root)
  if not c then
    return nil, "the container of " .. task.point .. " is not open"
  end
  local state = lernbaum.state_of_task(task)
  local reason = lernbaum.NEEDS_REASON[state]
      and (task.outcome_reason ~= nil and task.outcome_reason ~= "" and task.outcome_reason or "siehe " .. task.id)
    or nil
  local out
  local ok, err = fsio.with_lock(c.path, function()
    local cur = fsio.read(c.path)
    if not cur then
      return nil, "cannot read " .. c.path
    end
    local head, body = split_body(cur, c.path)
    if not head then
      return nil, "cannot read the body of " .. c.path
    end
    local tree = lernbaum.parse(body)
    local node = tree.by_key[key]
    if not node or node.promoted ~= task.id then
      return nil, ("%s has no point {#%s} that names %s"):format(c.id, key, task.id)
    end
    out = { container = c.id, key = key, state = state, changed = false }
    if node.state == state and (not reason or node.reason) then
      return true
    end
    local set, serr = lernbaum.set_state(tree, node.index, state, reason)
    if not set then
      return nil, serr
    end
    local text = head .. lernbaum.render(tree)
    text = fm.update_text(text, { { "updated", opts.today or model.today() } }) or text
    local wrote, werr = fsio.write_atomic(c.path, text)
    if not wrote then
      return nil, "cannot write " .. c.path .. ": " .. tostring(werr)
    end
    out.changed = true
    return true
  end)
  if not ok then
    return nil, err
  end
  return out, nil
end

---The open learning points of a task's own `## Lernpunkte` (leaves not closed), for the warning of `done`.
---@param text string  # The task file.
---@return integer
function M.open_points(text)
  local parsed = fm.parse(text)
  local tree = lernbaum.parse(parsed and parsed.body or text)
  return tree.progress.open
end

return M
