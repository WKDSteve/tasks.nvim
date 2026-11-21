---@module 'tasks_nvim.ui.learn'
---@brief The learning tree in the editor: marks, progress, folds, images and promoting the point under the cursor.
---@description
--- Works on a buffer that holds a learning path (`<area>/ROADMAP/paths/<slug>.md`) or a task with `## Lernpunkte`
--- (`tasks_nvim.lernbaum` reads the tree, the engine writes it):
---
---  - `cycle` / `set_point`: the mark of the point under the cursor, `[ ]` -> `[x]` -> `[~]` -> `[-]` -> `[ ]`; `[~]`
---    and `[-]` ask for the reason (`vim.ui.input`). An unchanged path buffer is written through `paths.point` (under
---    the file's lock, checked against the version on disk) and reloaded; a task file, or a buffer with unsaved
---    changes, is changed in the buffer (write it yourself). A promoted point is refused: its state belongs to the task.
---  - `attach` / `detach`: the view. The progress of each parent (and of the whole tree on the heading) as virtual text,
---    a placeholder line below each point with an image, folds per parent (`foldexpr`). Buffer-local autocommands
---    (group `TasksLearn`) keep it current; the keys of `keys.learning` are mapped buffer-local (none by default).
---  - `promote_at` / `unpromote_at` (and `promote_ref` / `unpromote_ref` for `:Tasks promote <id>#<key>`): the engine's
---    `tasks_nvim.promote`; the container is reloaded, a new task is opened.
---  - `image`: the image of the point under the cursor through images.nvim, else the file in mdview.nvim's browser
---    preview, else its path as a message. Neither is a dependency: without them everything stays text.
---
--- Not its job: the rules of the tree (`tasks_nvim.lernbaum`), writing files (`tasks_nvim.paths`,
--- `tasks_nvim.promote`), the route table (`tasks_nvim.ui.routes`).

local fm = require("lib.nvim.markdown.frontmatter")
local notify = require("lib.nvim.notify").create("[tasks]")

local fsio = require("tasks_nvim.fsio")
local lernbaum = require("tasks_nvim.lernbaum")
local lernlevel = require("tasks_nvim.lernlevel")
local soft = require("tasks_nvim.soft")
local vault = require("tasks_nvim.vault")

local M = {}

---The namespace of the virtual text.
M.ns = vim.api.nvim_create_namespace("tasks_learn")

---The augroup of the buffer-local autocommands of the view.
M.AUGROUP = "TasksLearn"

---The order `cycle` walks the marks in; a blocked point (or one with an unknown mark) goes back to open.
---@type table<string, string>
M.NEXT = { open = "learned", learned = "seen", seen = "dropped", dropped = "open" }

---The states `set_point` takes.
M.STATES = { "open", "learned", "seen", "dropped", "blocked" }

local MIDDOT = "\194\183" -- U+00B7

---@class Tasks.LearnState
---@field tick integer                        # The changedtick the folds were computed for.
---@field starts table<integer, integer>      # Buffer row -> fold level a parent starts.
---@field levels table<integer, integer>      # Buffer row -> fold level of the line.
---@field wins table<integer, table>          # Window -> its fold options before the view set them.
---@field keys string[]                       # The keys mapped in the buffer.
---@field level? integer                      # The highest level seen since the view was put on (said once).

---The buffers the view is attached to.
---@type table<integer, Tasks.LearnState>
local attached = {}

-- ── where the buffer is ──────────────────────────────────────────────────────

---@class Tasks.LearnFile
---@field id string
---@field area string
---@field slug string
---@field kind "path"|"task"
---@field path string
---@field root string

---Which path or task of the vault a buffer holds (by its file name: `<area>/ROADMAP/paths/<slug>.md`, `.../tasks/...`,
---or the folder form `<slug>/<slug>.md`).
---@param buf integer
---@return Tasks.LearnFile|nil file
---@return string|nil err
function M.locate(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil, "the buffer has no file"
  end
  local root, rerr = vault.root()
  if not root then
    return nil, rerr
  end
  local file = fsio.norm(name)
  if not fsio.is_inside(root, file) then
    -- the vault or the file reached over a link (macOS: /var is /private/var; a junction on Windows): compare where
    -- both really are
    local uv = vim.uv or vim.loop
    local real_root, real_file = uv.fs_realpath(root), uv.fs_realpath(file)
    if not (real_root and real_file and fsio.is_inside(real_root, real_file)) then
      return nil, "not a file of the vault: " .. file
    end
    root, file = fsio.norm(real_root), fsio.norm(real_file)
  end
  local rel = file:sub(#root + 2)
  for _, folder in ipairs({ "paths", "tasks" }) do
    local area, slug = rel:match("^([^/]+)/ROADMAP/" .. folder .. "/([^/]+)%.md$")
    if not area then
      local a, s, inner = rel:match("^([^/]+)/ROADMAP/" .. folder .. "/([^/]+)/([^/]+)%.md$")
      if a and s == inner then
        area, slug = a, s
      end
    end
    if area then
      return {
        id = area .. "/" .. slug,
        area = area,
        slug = slug,
        kind = folder == "paths" and "path" or "task",
        path = file,
        root = root,
      },
        nil
    end
  end
  return nil, "not a learning path or task file: " .. rel
end

---@class Tasks.LearnSnapshot
---@field tree Tasks.LernTree
---@field offset integer       # Buffer row of body line n is `offset + n`.
---@field heading? integer     # Buffer row of the `## Lernpunkte` heading.
---@field body string          # The text below the frontmatter (what `lernbaum` and `lernlevel` read).

---The tree of a buffer as it is now (unsaved changes included).
---@param buf integer
---@return Tasks.LearnSnapshot
function M.snapshot(buf)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local body, offset = text, 0
  local parsed = fm.parse(text)
  if parsed and parsed.has_block then
    local b = parsed.body or ""
    if #b == 0 or text:sub(-#b) == b then
      body = b
      local head = text:sub(1, #text - #b)
      offset = select(2, head:gsub("\n", ""))
    end
  end
  local tree = lernbaum.parse(body)
  -- the heading of the tree: the last `## Lernpunkte` above its first point (any case, as `lernbaum` reads it)
  local heading
  local first = tree.nodes[1] and tree.nodes[1].line or 0
  for i = 1, first - 1 do
    local hashes, name = tree.lines[i]:gsub("\r$", ""):match("^(#+)%s+(.-)%s*$")
    if hashes and #hashes == 2 then
      heading = nil
      for _, h in ipairs(lernbaum.HEADINGS) do
        if name:lower() == h:lower() then
          heading = offset + i
        end
      end
    end
  end
  return { tree = tree, offset = offset, heading = heading, body = body }
end

---Whether a buffer holds the text of a file (CRLF or LF, a byte order mark and the final newline aside).
---@param buf integer
---@param disk string
---@return boolean
function M.same_text(buf, disk)
  local text = disk:gsub("\r\n", "\n"):gsub("^\239\187\191", "")
  if text:sub(-1) == "\n" then
    text = text:sub(1, -2)
  end
  return text == table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---The point on buffer row `row` (1-based): the point's own line or one of its note lines (`> ` below it).
---@param snap Tasks.LearnSnapshot
---@param row integer
---@return Tasks.LernNode|nil
function M.node_at(snap, row)
  local rel = row - snap.offset
  local best
  for _, node in ipairs(snap.tree.nodes) do
    if node.line > rel then
      break
    end
    best = node
  end
  if not best then
    return nil
  end
  for l = best.line + 1, rel do
    local nws = (snap.tree.lines[l] or ""):match("^(%s*)>")
    if not nws or #nws <= best.indent then
      return nil
    end
  end
  return best
end

---@param win? integer
---@return integer buf
---@return integer row
local function cursor(win)
  win = win or 0
  return vim.api.nvim_win_get_buf(win), vim.api.nvim_win_get_cursor(win)[1]
end

---Reload an unchanged buffer from disk, the cursor and the view of each window kept.
---@param buf integer
local function reload(buf)
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].modified then
    return
  end
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
  -- reloading a Markdown buffer runs the undo of the runtime's ftplugin, whose `silent! nunmap` leaves E31 in
  -- v:errmsg without a message: a key or a script that checks v:errmsg afterwards would see an error that is none
  local errmsg = vim.v.errmsg
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent keepjumps edit!")
  end)
  vim.v.errmsg = errmsg
  for win, view in pairs(views) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  if attached[buf] then
    M.refresh(buf)
  end
end

---Reload every unchanged buffer of `path`; say so for a changed one.
---@param path string
local function reload_path(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and fsio.same_path(vim.api.nvim_buf_get_name(buf), path) then
      if vim.bo[buf].modified then
        notify.warn(path .. " changed on disk while its buffer has unsaved changes")
      else
        reload(buf)
      end
    end
  end
end

---The `xp:` of the promoted tasks per buffer, read once per set of arrows and again after a read or a write of the
---buffer (not on every change of its text: that would scan the vault per key).
---@type table<integer, { key: string, xp: table<string, integer|false> }>
local task_xp_cache = {}

---Give the promoted leaves of a snapshot the XP of their tasks (a buffer outside the vault keeps the points' own).
---@param buf integer
---@param snap Tasks.LearnSnapshot
local function with_task_xp(buf, snap)
  local ids = lernbaum.promoted_ids(snap.tree)
  if #ids == 0 then
    return
  end
  local key = table.concat(ids, ",")
  local hit = task_xp_cache[buf]
  if not (hit and hit.key == key) then
    local loc = M.locate(buf)
    if not loc then
      return
    end
    hit = { key = key, xp = require("tasks_nvim.paths").task_xp(snap.tree, loc.root) }
    task_xp_cache[buf] = hit
  end
  lernbaum.set_task_xp(snap.tree, hit.xp)
end

---Forget the task XP of a buffer (read again on the next draw).
---@param buf integer
function M.forget_task_xp(buf)
  task_xp_cache[buf] = nil
end

---Reload a path buffer the engine wrote on disk; the windows whose cursor was on `row` follow the point, not the row
---(the frontmatter can grow: `updated:` written the first time).
---@param buf integer
---@param row integer
---@param node Tasks.LernNode   # The point as it was before the write.
---@return Tasks.LernNode|nil node   # The point as it is now.
local function reload_following(buf, row, node)
  local wins = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_cursor(win)[1] == row then
      wins[#wins + 1] = win
    end
  end
  reload(buf)
  local after = M.snapshot(buf)
  local new_row = after.offset + node.line
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { new_row, vim.api.nvim_win_get_cursor(win)[2] })
    end
  end
  return M.node_at(after, new_row)
end

-- ── the mark of a point ──────────────────────────────────────────────────────

---Set the state of the point on `row` of `buf`. See the module head for where it is written.
---@param buf integer
---@param row integer
---@param state string
---@param reason? string
---@return Tasks.LernNode|nil node   # The point as it is now.
---@return string|nil err
function M.set_point(buf, row, state, reason)
  local snap = M.snapshot(buf)
  local node = M.node_at(snap, row)
  if not node then
    return nil, "no learning point on this line"
  end
  if node.promoted then
    return nil,
      ("the state of this point belongs to %s: finish (or take back) that task"):format(
        node.promoted
      )
  end
  local loc = M.locate(buf)
  if loc and loc.kind == "path" and not vim.bo[buf].modified then
    local disk, rerr = fsio.read(loc.path)
    if not disk then
      return nil, "cannot read " .. loc.path .. ": " .. tostring(rerr)
    end
    -- the buffer must be the file: the point is named by its position, and the version tag guards the write. The
    -- whole text is compared (line ends and the final newline aside): a point added above and a line taken away
    -- elsewhere would keep the row and move the position
    if not M.same_text(buf, disk) then
      return nil, loc.id .. " changed on disk: reload the buffer (:edit) first"
    end
    local res, err = require("tasks_nvim.paths").point(loc.id, node.index, state, reason, {
      root = loc.root,
      if_match = fsio.etag(disk),
    })
    if not res then
      return nil, err
    end
    -- a routine that waited for this point (`repeat_after: <path>#<key>`) has its first round now
    for _, r in ipairs(res.routines_started or {}) do
      notify.info(("routine %s starts: due %s"):format(r.id, r.due))
    end
    return reload_following(buf, row, node), nil
  end
  local changed, err = lernbaum.set_state(snap.tree, node.index, state, reason)
  if not changed then
    return nil, err
  end
  local lines = vim.split(lernbaum.render(snap.tree), "\n", { plain = true })
  local line = (lines[changed.line] or ""):gsub("\r$", "")
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { line })
  if attached[buf] then
    M.refresh(buf)
  end
  return changed, nil
end

---Ask for a reason (seen and dropped need one), then set the state. `done(node|nil, err|nil)` is called at the end;
---a cancelled question calls it with neither.
---@param buf integer
---@param row integer
---@param state string
---@param reason? string
---@param done? fun(node: Tasks.LernNode|nil, err: string|nil)
function M.set_point_asking(buf, row, state, reason, done)
  done = done or function(_, err)
    if err then
      notify.error(err)
    end
  end
  if not lernbaum.NEEDS_REASON[state] or (reason and reason ~= "") then
    return done(M.set_point(buf, row, state, reason))
  end
  local node = M.node_at(M.snapshot(buf), row)
  if not node then
    return done(nil, "no learning point on this line")
  end
  vim.ui.input({
    prompt = ("Grund (%s): "):format(state == "seen" and "angeschaut" or "entfällt"),
    default = node.reason or "",
  }, function(answer)
    if answer == nil then
      return done(nil, nil)
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return done(nil, "the buffer is gone")
    end
    if answer:match("^%s*$") then
      return done(nil, state .. " needs a reason")
    end
    done(M.set_point(buf, row, state, answer))
  end)
end

---The next mark of the point under the cursor (`[ ]` -> `[x]` -> `[~]` -> `[-]` -> `[ ]`).
---@param win? integer
function M.cycle(win)
  local buf, row = cursor(win)
  local node = M.node_at(M.snapshot(buf), row)
  if not node then
    notify.warn("no learning point on this line")
    return
  end
  if #node.children > 0 then
    notify.warn("a learning point with children has no mark of its own: change its children")
    return
  end
  M.set_point_asking(buf, row, M.NEXT[node.state or ""] or "open")
end

-- ── XP and rewards ───────────────────────────────────────────────────────────

---Set the XP of the point on `row` (`{xp=N}` in its line; nil or "" removes it), written like `set_point`: a path
---buffer without unsaved changes through `paths.point` on disk, else in the buffer. A parent sums its children; a point
---whose task carries `xp:` takes the task's (change it there).
---@param buf integer
---@param row integer
---@param xp integer|string|nil
---@return Tasks.LernNode|nil node
---@return string|nil err
function M.set_xp(buf, row, xp)
  local snap = M.snapshot(buf)
  local node = M.node_at(snap, row)
  if not node then
    return nil, "no learning point on this line"
  end
  if #node.children > 0 then
    return nil, "a learning point with children sums the XP of its children: change theirs"
  end
  if xp ~= nil and xp ~= "" and not lernbaum.to_xp(xp) then
    return nil,
      ("xp must be a whole number from 0 to %d, got %s"):format(lernbaum.MAX_XP, tostring(xp))
  end
  with_task_xp(buf, snap)
  if node.xp_from == "task" then
    return nil, ("the XP of this point is the xp: of %s: change it there"):format(node.promoted)
  end
  local loc = M.locate(buf)
  if loc and loc.kind == "path" and not vim.bo[buf].modified then
    local disk, rerr = fsio.read(loc.path)
    if not disk then
      return nil, "cannot read " .. loc.path .. ": " .. tostring(rerr)
    end
    if not M.same_text(buf, disk) then
      return nil, loc.id .. " changed on disk: reload the buffer (:edit) first"
    end
    local res, err = require("tasks_nvim.paths").point(loc.id, node.index, nil, nil, {
      root = loc.root,
      if_match = fsio.etag(disk),
      xp = xp == nil and "" or xp,
    })
    if not res then
      return nil, err
    end
    return reload_following(buf, row, node), nil
  end
  local changed, err = lernbaum.set_xp(snap.tree, node.index, xp)
  if not changed then
    return nil, err
  end
  local lines = vim.split(lernbaum.render(snap.tree), "\n", { plain = true })
  local line = (lines[changed.line] or ""):gsub("\r$", "")
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { line })
  if attached[buf] then
    M.refresh(buf)
  end
  return changed, nil
end

---Ask for the XP of the point on `row` (filled in with its own, else the engine's suggestion; empty removes it), then
---set it. `done(node|nil, err|nil)` at the end; a cancelled question calls it with neither.
---@param buf integer
---@param row integer
---@param done? fun(node: Tasks.LernNode|nil, err: string|nil)
function M.set_xp_asking(buf, row, done)
  done = done or function(_, err)
    if err then
      notify.error(err)
    end
  end
  local node = M.node_at(M.snapshot(buf), row)
  if not node then
    return done(nil, "no learning point on this line")
  end
  local default = node.xp_own or lernbaum.suggest_xp({ depth = node.depth })
  vim.ui.input({ prompt = "XP (leer: keine): ", default = tostring(default) }, function(answer)
    if answer == nil then
      return done(nil, nil)
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return done(nil, "the buffer is gone")
    end
    answer = vim.trim(answer)
    done(M.set_xp(buf, row, answer))
  end)
end

---Mark the reward of a level of the path in `buf` granted (`given`, "gegönnt") or not, on disk through
---`paths.set_reward` (the buffer must be the file, without unsaved changes), then reload it.
---@param buf integer
---@param ref string|integer   # The level number, or `done` for the line of the whole path.
---@param given boolean
---@return { ref: string, line: integer, given: boolean, before: boolean }|nil level
---@return string|nil err
function M.set_reward(buf, ref, given)
  local loc, lerr = M.locate(buf)
  if not loc then
    return nil, lerr
  end
  if loc.kind ~= "path" then
    return nil, "levels and rewards belong to a learning path (## Level), not to a task"
  end
  if vim.bo[buf].modified then
    return nil, "write the buffer first: the reward is marked in the file on disk"
  end
  local disk, rerr = fsio.read(loc.path)
  if not disk then
    return nil, "cannot read " .. loc.path .. ": " .. tostring(rerr)
  end
  if not M.same_text(buf, disk) then
    return nil, loc.id .. " changed on disk: reload the buffer (:edit) first"
  end
  local res, err = require("tasks_nvim.paths").set_reward(loc.id, ref, given, {
    root = loc.root,
    if_match = fsio.etag(disk),
  })
  if not res then
    return nil, err
  end
  reload(buf)
  return res.level, nil
end

-- ── the view ─────────────────────────────────────────────────────────────────

---Where an image of a point is on disk: below the folder of the file, under `assets/` (nil for anything else).
---@param file string
---@param image string
---@return string|nil
function M.image_path(file, image)
  if not image:match("^assets/") or image:find("..", 1, true) or image:find("\\", 1, true) then
    return nil
  end
  return fsio.dirname(file) .. "/" .. image
end

---@param buf integer
---@param snap Tasks.LearnSnapshot
local function compute_folds(buf, snap)
  local st = attached[buf]
  if not st then
    return
  end
  st.starts, st.levels = {}, {}
  for _, node in ipairs(snap.tree.nodes) do
    local first, last = lernbaum.subtree_range(snap.tree, node)
    if first and last then
      local level = node.depth + 1
      st.starts[snap.offset + node.line] = level
      for r = snap.offset + node.line, snap.offset + last do
        st.levels[r] = math.max(st.levels[r] or 0, level)
      end
    end
  end
  st.tick = vim.api.nvim_buf_get_changedtick(buf)
end

---Whether the view shows XP, level and rewards (`setup({ gamification = false })` hides them).
---@return boolean
function M.gamified()
  return require("tasks_nvim.config").get().gamification ~= false
end

---Say once, in one quiet line (no popup), that a level was reached.
---@param text string
function M.say(text)
  vim.api.nvim_echo({ { "[tasks] " .. text, "Comment" } }, true, {})
end

---The heading's text after the progress: `120 / 300 XP · Level 2 (Einsteiger) · Belohnung offen: Kino`.
---@param tree Tasks.LernTree
---@param ls? Tasks.LevelState
---@return string
function M.xp_text(tree, ls)
  local parts = {}
  local sep = " " .. MIDDOT .. " "
  if tree.has_xp then
    parts[#parts + 1] = ("%d / %d XP"):format(tree.xp.earned, tree.xp.possible)
  end
  if ls and ls.has_levels then
    if ls.level > 0 then
      parts[#parts + 1] = "Level "
        .. ls.level
        .. (ls.level_name and (" (" .. ls.level_name .. ")") or "")
    end
    local rewards = {}
    for _, r in ipairs(ls.open_rewards) do
      rewards[#rewards + 1] = r.reward
    end
    if #rewards > 0 then
      parts[#parts + 1] = "Belohnung offen: " .. table.concat(rewards, ", ")
    end
  end
  return table.concat(parts, sep)
end

---Draw the progress and the image placeholders anew (and the folds of an attached buffer).
---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local snap = M.snapshot(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local function mark(row, opts)
    if row >= 1 and row <= count then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row - 1, 0, opts)
    end
  end
  local game = M.gamified() and #snap.tree.nodes > 0
  local ls
  if game then
    with_task_xp(buf, snap)
    local lv = lernlevel.parse(snap.body)
    if #lv.levels > 0 or lv.final then
      ls = lernlevel.evaluate(lv, snap.tree)
    end
    local st = attached[buf]
    if st and ls then
      -- a level reached while the view is on says so once; the level the buffer opened with does not
      if st.level and ls.level > st.level then
        M.say(
          ("Level %d erreicht%s"):format(ls.level, ls.level_name and (": " .. ls.level_name) or "")
        )
      end
      st.level = math.max(st.level or 0, ls.level)
    end
  end
  if snap.heading and #snap.tree.nodes > 0 then
    local text = lernbaum.progress_text(snap.tree.progress)
    local extra = game and M.xp_text(snap.tree, ls) or ""
    if extra ~= "" then
      text = text .. " " .. MIDDOT .. " " .. extra
    end
    mark(snap.heading, {
      virt_text = { { "  " .. text, "Comment" } },
      virt_text_pos = "eol",
    })
  end
  for _, node in ipairs(snap.tree.nodes) do
    local row = snap.offset + node.line
    if #node.children > 0 then
      mark(row, {
        virt_text = { { "  " .. lernbaum.progress_text(node.progress), "Comment" } },
        virt_text_pos = "eol",
      })
    elseif game and node.xp then
      mark(row, { virt_text = { { "  " .. node.xp .. " XP", "Comment" } }, virt_text_pos = "eol" })
    end
    if node.image then
      local abs = file ~= "" and M.image_path(fsio.norm(file), node.image) or nil
      local text = "[image] " .. node.image
      if not abs then
        text = text .. " (not below assets/)"
      elseif not fsio.is_file(abs) then
        text = text .. " (missing)"
      end
      local indent = string.rep(" ", node.indent + 2)
      mark(row, { virt_lines = { { { indent .. text, "Comment" } } } })
    end
  end
  if attached[buf] then
    compute_folds(buf, snap)
  end
end

---The fold level of a line of an attached buffer (`foldexpr`): a parent starts a fold of `depth + 1`, its subtree is in it.
---@param lnum? integer
---@return string
function M.foldexpr(lnum)
  lnum = lnum or vim.v.lnum
  local buf = vim.api.nvim_get_current_buf()
  local st = attached[buf]
  if not st then
    return "0"
  end
  if st.tick ~= vim.api.nvim_buf_get_changedtick(buf) then
    compute_folds(buf, M.snapshot(buf))
  end
  local start = st.starts[lnum]
  if start then
    return ">" .. start
  end
  return tostring(st.levels[lnum] or 0)
end

local FOLD_OPTIONS = { "foldmethod", "foldexpr", "foldlevel" }

---@param buf integer
---@param win integer
local function fold_window(buf, win)
  local st = attached[buf]
  if not st or st.wins[win] or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local old = {}
  for _, name in ipairs(FOLD_OPTIONS) do
    old[name] = vim.api.nvim_get_option_value(name, { win = win, scope = "local" })
  end
  st.wins[win] = old
  vim.api.nvim_set_option_value(
    "foldexpr",
    "v:lua.require'tasks_nvim.ui.learn'.foldexpr()",
    { win = win, scope = "local" }
  )
  vim.api.nvim_set_option_value("foldmethod", "expr", { win = win, scope = "local" })
  vim.api.nvim_set_option_value("foldlevel", 99, { win = win, scope = "local" })
end

---Whether the view is attached to a buffer.
---@param buf integer
---@return boolean
function M.is_attached(buf)
  return attached[buf] ~= nil
end

---The actions `keys.learning` can bind, to what they do.
---@type table<string, { desc: string, run: fun() }>
M.ACTIONS = {
  cycle = {
    desc = "Learning point: next mark",
    run = function()
      M.cycle()
    end,
  },
  promote = {
    desc = "Learning point: promote to a task",
    run = function()
      M.promote_at()
    end,
  },
  unpromote = {
    desc = "Learning point: take the promotion back",
    run = function()
      M.unpromote_at()
    end,
  },
  image = {
    desc = "Learning point: show its image",
    run = function()
      M.image()
    end,
  },
  follow = {
    desc = "Learning point: open the task it was promoted to",
    run = function()
      M.follow()
    end,
  },
  xp = {
    desc = "Learning point: set its XP",
    run = function()
      local buf, row = cursor()
      M.set_xp_asking(buf, row)
    end,
  },
}

---Attach the view to a buffer: progress, image placeholders, folds, buffer-local autocommands and keys. Again on an
---attached buffer: drawn anew.
---@param buf? integer
function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if attached[buf] then
    M.refresh(buf)
    return
  end
  attached[buf] = { tick = -1, starts = {}, levels = {}, wins = {}, keys = {} }
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    fold_window(buf, win)
  end
  local group = vim.api.nvim_create_augroup(M.AUGROUP, { clear = false })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost", "BufReadPost" }, {
    group = group,
    buffer = buf,
    desc = "tasks.nvim: redraw the learning tree",
    callback = function(ev)
      if ev.event == "BufReadPost" or ev.event == "BufWritePost" then
        -- the tasks may have changed meanwhile: their XP is read again
        task_xp_cache[ev.buf] = nil
      end
      M.refresh(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    desc = "tasks.nvim: folds of the learning tree in a new window",
    callback = function(ev)
      fold_window(ev.buf, vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    desc = "tasks.nvim: forget the learning tree view",
    callback = function(ev)
      attached[ev.buf] = nil
      task_xp_cache[ev.buf] = nil
    end,
  })
  local keys = require("tasks_nvim.config").get().keys.learning or {}
  local names = vim.tbl_keys(keys)
  table.sort(names)
  for _, action in ipairs(names) do
    local key = keys[action]
    local def = M.ACTIONS[action]
    if type(key) == "string" and key ~= "" and def then
      vim.keymap.set("n", key, def.run, { buffer = buf, desc = def.desc, silent = true })
      table.insert(attached[buf].keys, key)
    end
  end
  M.refresh(buf)
end

---Take the view off a buffer: virtual text, folds (the window's options as they were), autocommands and keys.
---@param buf? integer
function M.detach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local st = attached[buf]
  if not st then
    return
  end
  attached[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    pcall(vim.api.nvim_clear_autocmds, { group = M.AUGROUP, buffer = buf })
    for _, key in ipairs(st.keys) do
      pcall(vim.keymap.del, "n", key, { buffer = buf })
    end
  end
  for win, old in pairs(st.wins) do
    if vim.api.nvim_win_is_valid(win) then
      for _, name in ipairs(FOLD_OPTIONS) do
        pcall(vim.api.nvim_set_option_value, name, old[name], { win = win, scope = "local" })
      end
    end
  end
end

---Attach when it is off, detach when it is on.
---@param buf? integer
---@return boolean on
function M.toggle(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if attached[buf] then
    M.detach(buf)
    return false
  end
  M.attach(buf)
  return true
end

---For `learning = { auto = true }`: attach to a buffer of a path or a task with `## Lernpunkte` when it is shown.
---@param buf integer
function M.auto(buf)
  if attached[buf] or not M.locate(buf) then
    return
  end
  if M.snapshot(buf).tree.has_section then
    M.attach(buf)
  end
end

---Register (or with `false` remove) the autocommand of `learning.auto` (group `TasksLearnAuto`).
---@param on boolean
function M.enable_auto(on)
  if not on then
    pcall(vim.api.nvim_del_augroup_by_name, "TasksLearnAuto")
    return
  end
  local group = vim.api.nvim_create_augroup("TasksLearnAuto", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    pattern = "*.md",
    desc = "tasks.nvim: the learning tree view on paths and learning tasks",
    callback = function(ev)
      M.auto(ev.buf)
    end,
  })
end

-- ── images and arrows ────────────────────────────────────────────────────────

---Show the image of the point under the cursor: images.nvim in the terminal, else mdview.nvim's browser preview of the
---file, else the path as a message.
---@param win? integer
---@return "images"|"mdview"|"text"|nil how
function M.image(win)
  local buf, row = cursor(win)
  local node = M.node_at(M.snapshot(buf), row)
  if not (node and node.image) then
    notify.warn("no image on this learning point")
    return nil
  end
  local file = fsio.norm(vim.api.nvim_buf_get_name(buf))
  local abs = M.image_path(file, node.image)
  if not abs then
    notify.error("an image must be a file below assets/: " .. node.image)
    return nil
  end
  if not fsio.is_file(abs) then
    notify.error("image missing: " .. abs)
    return nil
  end
  local images = soft.check({ "show" }, pcall(require, "images"))
  if images and images.show(abs) then
    return "images"
  end
  local preview = require("tasks_nvim.ui.preview")
  if preview.available() then
    local ok = preview.open_file(file)
    if ok then
      return "mdview"
    end
  end
  notify.info("image: " .. abs .. " (images.nvim or mdview.nvim shows it)")
  return "text"
end

---Open the task the point under the cursor was promoted to.
---@param win? integer
---@return string|nil path
function M.follow(win)
  local buf, row = cursor(win)
  local node = M.node_at(M.snapshot(buf), row)
  if not (node and node.promoted) then
    notify.warn("this learning point was not promoted")
    return nil
  end
  local scan = require("tasks_nvim.scan")
  local task = scan.find(node.promoted) or scan.find_done(node.promoted)
  if not task then
    notify.error("no such task: " .. node.promoted)
    return nil
  end
  require("tasks_nvim.ui.cmd").open_file(task.path)
  return task.path
end

-- ── promote ──────────────────────────────────────────────────────────────────

---@class Tasks.LearnPromoteOpts
---@field area? string
---@field title? string
---@field actor? string
---@field tags? string     # More tags (comma list); the container's machine tags come along anyway.
---@field after? string    # Ids the task comes after (comma list).
---@field effort? string
---@field dry_run? boolean
---@field index? boolean
---@field open? boolean    # Open the new task (default true).

---Promote `<container>#<ref>` (the engine's `promote.promote`), reload the container's buffers and open the new task.
---@param container string
---@param ref string|integer
---@param opts? Tasks.LearnPromoteOpts
---@return table|nil result
function M.promote_ref(container, ref, opts)
  opts = opts or {}
  local res, err = require("tasks_nvim.promote").promote(container, ref, {
    area = opts.area,
    title = opts.title,
    actor = opts.actor,
    tags = opts.tags,
    after = opts.after,
    effort = opts.effort,
    dry_run = opts.dry_run,
    index = opts.index,
  })
  if not res then
    notify.error(tostring(err))
    return nil
  end
  if res.dry_run then
    notify.info(("would promote %s to %s (%d line(s) move)"):format(res.point, res.id, res.moved))
    return res
  end
  local found = require("tasks_nvim.paths").find(res.container)
  local cpath = found and found.path
  if not cpath then
    local t = require("tasks_nvim.scan").find(res.container)
    cpath = t and t.path
  end
  if cpath then
    reload_path(cpath)
  end
  if opts.open ~= false and res.path then
    require("tasks_nvim.ui.cmd").open_file(res.path)
  end
  notify.info(("promoted %s to %s (%d line(s) moved)"):format(res.point, res.id, res.moved))
  return res
end

---Take back `<container>#<ref>` (the engine's `promote.unpromote`) and reload the container's buffers.
---@param container string
---@param ref string|integer
---@param opts? { dry_run?: boolean, index?: boolean }
---@return table|nil result
function M.unpromote_ref(container, ref, opts)
  opts = opts or {}
  local res, err = require("tasks_nvim.promote").unpromote(container, ref, {
    dry_run = opts.dry_run,
    index = opts.index,
  })
  if not res then
    notify.error(tostring(err))
    return nil
  end
  if res.dry_run then
    notify.info(
      ("would take back %s#%s (task %s)"):format(res.container, tostring(res.key), res.id)
    )
    return res
  end
  local found = require("tasks_nvim.paths").find(res.container)
  local cpath = found and found.path
  if not cpath then
    local t = require("tasks_nvim.scan").find(res.container)
    cpath = t and t.path
  end
  if cpath then
    reload_path(cpath)
  end
  notify.info(
    ("took back %s#%s (task %s removed)"):format(res.container, tostring(res.key), res.id)
  )
  return res
end

---The container and point under the cursor, for promoting: the buffer must be a file of the vault without unsaved
---changes (the engine writes the file on disk).
---@param win? integer
---@return Tasks.LearnFile|nil file
---@return Tasks.LernNode|nil node
---@return string|nil err
local function here(win)
  local buf, row = cursor(win)
  local loc, lerr = M.locate(buf)
  if not loc then
    return nil, nil, lerr
  end
  if vim.bo[buf].modified then
    return nil, nil, "write the buffer first: the point is changed in the file on disk"
  end
  local node = M.node_at(M.snapshot(buf), row)
  if not node then
    return nil, nil, "no learning point on this line"
  end
  return loc, node, nil
end

---Promote the point under the cursor.
---@param opts? Tasks.LearnPromoteOpts
---@param win? integer
---@return table|nil result
function M.promote_at(opts, win)
  local loc, node, err = here(win)
  if not (loc and node) then
    notify.error(tostring(err))
    return nil
  end
  return M.promote_ref(loc.id, node.key or node.index, opts)
end

---Take back the promotion of the point under the cursor.
---@param opts? { dry_run?: boolean, index?: boolean }
---@param win? integer
---@return table|nil result
function M.unpromote_at(opts, win)
  local loc, node, err = here(win)
  if not (loc and node) then
    notify.error(tostring(err))
    return nil
  end
  if not node.promoted then
    notify.error("this learning point was not promoted")
    return nil
  end
  return M.unpromote_ref(loc.id, node.key or node.index, opts)
end

-- ── the :Tasks verbs ─────────────────────────────────────────────────────────

---@param ctx table
---@return boolean
local function no_rest(ctx)
  if ctx.rest and #ctx.rest > 0 then
    notify.error("unexpected argument: " .. table.concat(ctx.rest, " "))
    return false
  end
  return true
end

---`<container>#<ref>`: the container id and the key (or `n` / `#n`, a position), as the CLI reads it.
---@param arg string
---@return string|nil container
---@return string|integer|nil ref
function M.point_arg(arg)
  local container, ref = (arg or ""):match("^([^#%s]+/[^#%s]+)#(%S+)$")
  if not container then
    return nil
  end
  return container, tonumber(ref) or ref
end

---`:Tasks learn [toggle|on|off|image|follow]`
---@param ctx table
function M.cmd_learn(ctx)
  if not no_rest(ctx) then
    return
  end
  local action = ctx.args.action or "toggle"
  if action == "image" then
    M.image()
  elseif action == "follow" then
    M.follow()
  elseif action == "off" then
    M.detach()
  else
    local buf = vim.api.nvim_get_current_buf()
    if action == "on" or not attached[buf] then
      if not M.snapshot(buf).tree.has_section then
        notify.warn("this buffer has no ## Lernpunkte")
      end
      M.attach(buf)
    else
      M.detach(buf)
    end
  end
end

---`:Tasks point [next|open|learned|seen|dropped|blocked] [reason...]`
---@param ctx table
function M.cmd_point(ctx)
  local state = ctx.args.state or "next"
  local reason = ctx.rest and #ctx.rest > 0 and table.concat(ctx.rest, " ") or nil
  local buf, row = cursor()
  if state == "next" then
    if reason then
      notify.error("a reason goes with seen or dropped: :Tasks point seen <reason>")
      return
    end
    M.cycle()
    return
  end
  if reason and not lernbaum.NEEDS_REASON[state] then
    notify.error(("%s takes no reason: %s"):format(state, reason))
    return
  end
  M.set_point_asking(buf, row, state, reason)
end

---`:Tasks xp [<n>|clear]`: the XP of the point under the cursor; without a value a question, filled in with its own or
---the engine's suggestion.
---@param ctx table
function M.cmd_xp(ctx)
  if not no_rest(ctx) then
    return
  end
  local buf, row = cursor()
  local value = ctx.args.value
  if value == nil then
    M.set_xp_asking(buf, row)
    return
  end
  local node, err = M.set_xp(buf, row, value == "clear" and "" or value)
  if not node then
    notify.error(tostring(err))
  end
end

---`:Tasks reward <n|done> [--undo]`: the reward of a level of the path in this buffer granted ("gegönnt"), or not.
---@param ctx table
function M.cmd_reward(ctx)
  if not no_rest(ctx) then
    return
  end
  local undo = ctx.flags.undo == true
  local level, err = M.set_reward(vim.api.nvim_get_current_buf(), ctx.args.level, not undo)
  if not level then
    notify.error(tostring(err))
    return
  end
  local label = level.ref == "done" and "Pfad fertig" or ("Level " .. level.ref)
  notify.info(("%s: Belohnung %s"):format(label, undo and "wieder offen" or "gegönnt"))
end

---`:Tasks promote [<area>/<slug>#<key|n>] [--area= --title= --actor= --dry-run --no-index]`
---@param ctx table
function M.cmd_promote(ctx)
  if not no_rest(ctx) then
    return
  end
  local opts = {
    area = ctx.flags.area,
    title = ctx.flags.title,
    actor = ctx.flags.actor,
    tags = ctx.flags.tags,
    after = ctx.flags.after,
    effort = ctx.flags.effort,
    dry_run = ctx.flags["dry-run"] == true,
    index = not ctx.flags["no-index"],
  }
  if ctx.args.point then
    local container, ref = M.point_arg(ctx.args.point)
    if not container then
      notify.error("not a learning point <area>/<slug>#<key|n>: " .. ctx.args.point)
      return
    end
    M.promote_ref(container, ref, opts)
    return
  end
  M.promote_at(opts)
end

---`:Tasks unpromote [<area>/<slug>#<key|n>] [--dry-run --no-index]`
---@param ctx table
function M.cmd_unpromote(ctx)
  if not no_rest(ctx) then
    return
  end
  local opts = { dry_run = ctx.flags["dry-run"] == true, index = not ctx.flags["no-index"] }
  if ctx.args.point then
    local container, ref = M.point_arg(ctx.args.point)
    if not container then
      notify.error("not a learning point <area>/<slug>#<key|n>: " .. ctx.args.point)
      return
    end
    M.unpromote_ref(container, ref, opts)
    return
  end
  M.unpromote_at(opts)
end

return M
