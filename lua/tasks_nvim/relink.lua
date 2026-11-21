---@module 'tasks_nvim.relink'
-- @scans-data: the folders it lists and the files it rewrites are task vaults, never the files of this plugin
---@brief Keep relative Markdown links on their file when files move (`done`, `reopen`, `move_area`, `folderize`), and repair the dead ones a move left behind before this existed.
---@description
--- One rule for every move: a relative link is rewritten only when, after the move, it would name another file than
--- the one it named before. A link that still resolves to the same file keeps its text, so moving there and back gives
--- the text it had (`done` then `reopen`, `move_area` and back: each is the other's inverse).
---
--- `follow` runs after a move: the links of the files below `ROADMAP/` and `MEETINGS/` of every area that named a moved
--- file (or a file in a moved folder) follow it, and so do the links of a moved file itself (its folder changed). The
--- history below `Backlog/` is not read on every move (it is the largest part of a vault): `repair` covers it.
---
--- `repair` mends what is dead already: a relative link to a `.md` file that is not there is rewritten to the one file
--- of that slug (`<slug>.md`, its folder form, or `YYYY-MM-DD_<slug>` in a Backlog), preferring the area the link
--- named; several such files are reported, never guessed.
---
--- Not its job: what a link is (`tasks_nvim.mdlinks`), wikilinks and ids in the frontmatter (`tasks_nvim.moves`).

local fsio = require("tasks_nvim.fsio")
local mdlinks = require("tasks_nvim.mdlinks")
local vault = require("tasks_nvim.vault")

local M = {}

---The folders of an area whose files `follow` reads after a move.
M.FOLLOW_DIRS = { "ROADMAP", "MEETINGS" }

---The folders of an area whose files `repair` reads.
M.REPAIR_DIRS = { "ROADMAP", "Backlog", "MEETINGS" }

local DATE_PREFIX = "^%d%d%d%d%-%d%d%-%d%d_"

---@class Tasks.RelinkMove
---@field from string  # The file or folder before the move (absolute).
---@field to string    # Where it is now.

---@class Tasks.RelinkEdit
---@field path string  # The file the link stands in (where it is now).
---@field line integer
---@field from string  # The target as it was written.
---@field to string    # The target written instead.

---@class Tasks.RelinkResult
---@field links integer             # Links rewritten (or, for a dry run, to be).
---@field files string[]            # Files changed.
---@field edits Tasks.RelinkEdit[]
---@field errors string[]           # Files that could not be written (the move itself stays).

local is_windows = require("lib.nvim.cross.platform.is_windows")()

---A path in the form two paths are compared by.
---@param p string
---@return string
local function key(p)
  p = fsio.norm(p)
  return is_windows and p:lower() or p
end

---@param p string
---@return string lead  # `E:/`, `/` or ``
---@return string[] parts
local function split(p)
  p = fsio.norm(p)
  local lead = p:match("^%a:/") or p:match("^/+") or ""
  local parts = {}
  for seg in p:sub(#lead + 1):gmatch("[^/]+") do
    parts[#parts + 1] = seg
  end
  return lead, parts
end

---The path of `path` seen from the folder `dir` (`../x/y.md`), or nil when they share no root (another drive).
---@param dir string
---@param path string
---@return string|nil
function M.relpath(dir, path)
  local dl, dp = split(dir)
  local pl, pp = split(path)
  if key(dl) ~= key(pl) then
    return nil
  end
  local i = 1
  while i <= #dp and i <= #pp and key(dp[i]) == key(pp[i]) do
    i = i + 1
  end
  local out = {}
  for _ = i, #dp do
    out[#out + 1] = ".."
  end
  for j = i, #pp do
    out[#out + 1] = pp[j]
  end
  return table.concat(out, "/")
end

---Where `path` is after the moves (unchanged when no move touched it). A file move wins over a folder move.
---@param path string
---@param moves Tasks.RelinkMove[]
---@param field_from string  # "from" to map forward, "to" to map back
---@param field_to string
---@return string
local function map(path, moves, field_from, field_to)
  local k = key(path)
  for _, mv in ipairs(moves) do
    if k == key(mv[field_from]) then
      return fsio.norm(mv[field_to])
    end
  end
  for _, mv in ipairs(moves) do
    local base = key(mv[field_from])
    if k:sub(1, #base + 1) == base .. "/" then
      return fsio.norm(mv[field_to]) .. fsio.norm(path):sub(#base + 1)
    end
  end
  return path
end

---A new target for a link that must name `abs` from `dir`, written the way the old one was: the `#anchor` / `?query`
---kept, blanks escaped unless the link was in `<...>`, a leading `./` kept.
---@param old string     # The target as written.
---@param angle boolean  # It stood in `<...>`.
---@param dir string
---@param abs string
---@return string|nil
local function written(old, angle, dir, abs)
  local rel = M.relpath(dir, abs)
  if not rel or rel == "" then
    return nil
  end
  if not angle then
    rel = rel:gsub(" ", "%%20")
  end
  -- a leading `./` stays, also before a `../`: the way back then writes the text the link had
  if old:match("^%./") then
    rel = "./" .. rel
  end
  return rel .. (old:match("[#?].*$") or "")
end

---A target as a path: without `./`, `#anchor` and `?query`, percent-escapes decoded.
---@param target string
---@return string
local function plain_target(target)
  local t = target:gsub("[#?].*$", ""):gsub("^%./", "")
  return (t:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---Rewrite `text` so that each relative link names after the moves what it named before. `old_dir` is the folder the
---file was in, `new_dir` the one it is in now (the same for a file that did not move). `pick(abs, link)` may give the
---file a link should name instead of the one it resolves to (`repair`); nil keeps the rule of the moves.
---@param text string
---@param old_dir string
---@param new_dir string
---@param moves Tasks.RelinkMove[]
---@param pick? fun(abs: string, link: Tasks.MdLink): string|nil
---@return string text
---@return { line: integer, from: string, to: string }[] edits
function M.rewrite(text, old_dir, new_dir, moves, pick)
  local by_line, edits = {}, {}
  local lines = vim.split(text, "\n", { plain = true })
  local moved = key(old_dir) ~= key(new_dir)
  for _, l in ipairs(mdlinks.scan(text)) do
    if mdlinks.is_relative(l.target) then
      local before = mdlinks.resolve(old_dir, l.target)
      if before then
        local want = pick and pick(before, l) or map(before, moves, "from", "to")
        local now = mdlinks.resolve(new_dir, l.target)
        -- in a file that moved, a link written the shortest way from the old folder is written the shortest way from
        -- the new one, though the old text still resolves (`../../ROADMAP/tasks/y.md` back in `ROADMAP/tasks` is `y.md`)
        local shortest = moved and want and plain_target(l.target) == M.relpath(old_dir, before)
        if want and (key(now) ~= key(want) or shortest) then
          local line = lines[l.line] or ""
          local angle = line:sub(l.col - 1, l.col - 1) == "<"
          local new = written(l.target, angle, new_dir, want)
          if new and new ~= l.target then
            by_line[l.line] = by_line[l.line] or {}
            table.insert(by_line[l.line], { l = l, new = new })
            edits[#edits + 1] = { line = l.line, from = l.target, to = new }
          end
        end
      end
    end
  end
  if #edits == 0 then
    return text, edits
  end
  for lnum, list in pairs(by_line) do
    local line = lines[lnum]
    for i = #list, 1, -1 do
      local e = list[i]
      line = line:sub(1, e.l.col - 1) .. e.new .. line:sub(e.l.col_end + 1)
    end
    lines[lnum] = line
  end
  return table.concat(lines, "\n"), edits
end

---The `.md` files below `dir`, recursively (hidden folders left out).
---@param dir string
---@param out string[]
local function md_files(dir, out)
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:sub(1, 1) ~= "." then
      local p = dir .. "/" .. name
      if not kind or kind == "unknown" then
        local st = uv.fs_lstat(p)
        kind = st and st.type or "unknown"
      end
      if kind == "directory" then
        md_files(p, out)
      elseif kind == "file" and name:match("%.md$") then
        out[#out + 1] = p
      end
    end
  end
end

---The files of the areas `names` (nil: every area) below the folders `dirs`.
---@param root string
---@param dirs string[]
---@param names? string[]
---@return string[]
function M.files(root, dirs, names)
  local out = {}
  local want
  if names then
    want = {}
    for _, n in ipairs(names) do
      want[n] = true
    end
  end
  for _, a in ipairs(vault.areas(root)) do
    if not want or want[a.name] then
      for _, d in ipairs(dirs) do
        md_files(fsio.norm(a.path) .. "/" .. d, out)
      end
    end
  end
  table.sort(out)
  return out
end

---Rewrite one file under its lock, on the text it has now. A dry run writes nothing.
---@param path string
---@param fn fun(text: string): string, table[]
---@param dry boolean
---@param res Tasks.RelinkResult
local function apply(path, fn, dry, res)
  local edits
  local function step()
    local text = fsio.read(path)
    if not text then
      return true
    end
    local new
    new, edits = fn(text)
    if dry or #edits == 0 then
      return true
    end
    return fsio.write_atomic(path, new)
  end
  local ok, err
  if dry then
    ok, err = step()
  else
    ok, err = fsio.with_lock(path, step)
  end
  if not ok then
    res.errors[#res.errors + 1] = ("%s: %s"):format(path, tostring(err))
    return
  end
  if edits and #edits > 0 then
    res.files[#res.files + 1] = path
    for _, e in ipairs(edits) do
      res.links = res.links + 1
      res.edits[#res.edits + 1] = { path = path, line = e.line, from = e.from, to = e.to }
    end
  end
end

---@return Tasks.RelinkResult
local function result()
  return { links = 0, files = {}, edits = {}, errors = {} }
end

---After `moves` happened: the links that named a moved file (or a file in a moved folder) follow it, in the files below
---`ROADMAP/` and `MEETINGS/` of every area and in the moved files themselves. `opts.skip` names files whose own links
---were moved already (`folderize`). Never raises; what could not be written is in `errors`.
---@param root string
---@param moves Tasks.RelinkMove[]
---@param opts? { skip?: string[] }
---@return Tasks.RelinkResult
function M.follow(root, moves, opts)
  opts = opts or {}
  local res = result()
  if #moves == 0 then
    return res
  end
  local skip = {}
  for _, p in ipairs(opts.skip or {}) do
    skip[key(p)] = true
  end
  -- a file's text is read only when it can hold such a link: the name of a moved file or folder, or it moved itself
  local needles = {}
  for _, mv in ipairs(moves) do
    local name = fsio.norm(mv.from):match("([^/]+)$")
    if name then
      needles[#needles + 1] = name
      needles[#needles + 1] = (name:gsub(" ", "%%20"))
    end
  end
  local seen = {}
  local files = M.files(root, M.FOLLOW_DIRS)
  for _, mv in ipairs(moves) do
    if fsio.is_file(mv.to) then
      files[#files + 1] = fsio.norm(mv.to)
    else
      md_files(fsio.norm(mv.to), files)
    end
  end
  for _, path in ipairs(files) do
    local k = key(path)
    if not seen[k] and not skip[k] then
      seen[k] = true
      local old = map(path, moves, "to", "from")
      local moved = key(old) ~= k
      local ok, err = pcall(apply, path, function(text)
        if not moved then
          local hit = false
          for _, n in ipairs(needles) do
            if text:find(n, 1, true) then
              hit = true
              break
            end
          end
          if not hit then
            return text, {}
          end
        end
        return M.rewrite(text, fsio.dirname(old), fsio.dirname(path), moves)
      end, false, res)
      if not ok then
        res.errors[#res.errors + 1] = ("%s: %s"):format(path, tostring(err))
      end
    end
  end
  return res
end

---The files of the vault by slug, for `repair`: tasks (plain and folder), plans, projects, learning paths, and the
---finished ones in the Backlogs (`YYYY-MM-DD_<slug>`), each an absolute path.
---@param root string
---@return table<string, string[]>
local function slug_index(root)
  local by_slug = {}
  local function add(slug, path)
    local list = by_slug[slug] or {}
    list[#list + 1] = fsio.norm(path)
    by_slug[slug] = list
  end
  local idx = require("tasks_nvim.wikilinks").build_index(root)
  for slug, ids in pairs(idx.by_slug) do
    for _, id in ipairs(ids) do
      add(slug, fsio.norm(root) .. "/" .. idx.path_of[id] .. ".md")
    end
  end
  local uv = vim.uv or vim.loop
  for _, a in ipairs(vault.areas(root)) do
    local dir = vault.paths_dir(root, a.name)
    local handle = uv.fs_scandir(dir)
    while handle do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local slug = name:match("^(.+)%.md$")
      if slug and kind ~= "directory" then
        add(slug, dir .. "/" .. name)
      elseif kind == "directory" and fsio.is_file(dir .. "/" .. name .. "/" .. name .. ".md") then
        add(name, dir .. "/" .. name .. "/" .. name .. ".md")
      end
    end
  end
  return by_slug
end

---The folders a finished file of a Backlog was in while it was open (`done` and `plan_close` moved it from there): for
---`<area>/Backlog/<BUCKET>/<date>_<slug>.md` the folders below `<area>/ROADMAP/` (`tasks`, `plans`, `projects`,
---`paths`), for its folder form `<date>_<slug>/<date>_<slug>.md` the folder `<slug>` in each. Empty for any other file.
---@param rootn string  # The vault root, normalised.
---@param path string
---@return string[]
local function open_dirs(rootn, path)
  local rel = fsio.norm(path):sub(#rootn + 2)
  local area, rest = rel:match("^([^/]+)/Backlog/%u+/(.+)$")
  if not area then
    return {}
  end
  local folder = rest:match("^([^/]+)/[^/]+%.md$")
  if not folder and rest:find("/", 1, true) then
    return {}
  end
  local slug = folder and folder:gsub(DATE_PREFIX, "") or nil
  local out = {}
  for _, kind in ipairs({ "tasks", "plans", "projects", "paths" }) do
    out[#out + 1] = rootn .. "/" .. area .. "/ROADMAP/" .. kind .. (slug and ("/" .. slug) or "")
  end
  return out
end

---@class Tasks.RelinkRepair: Tasks.RelinkResult
---@field ambiguous { path: string, line: integer, target: string, candidates: string[] }[]
---@field unresolved { path: string, line: integer, target: string }[]

---Mend the dead relative links to `.md` files in the areas `names` (nil: all), below `ROADMAP/`, `Backlog/` and
---`MEETINGS/`: a link whose slug names exactly one file (in the area the link named, else in the vault) is rewritten
---to it; several are `ambiguous`, none `unresolved`. `opts.dry_run` writes nothing.
---@param root string
---@param names? string[]
---@param opts? { dry_run?: boolean }
---@return Tasks.RelinkRepair
function M.repair(root, names, opts)
  opts = opts or {}
  local res = result() --[[@as Tasks.RelinkRepair]]
  res.ambiguous, res.unresolved = {}, {}
  local by_slug = slug_index(root)
  local rootn = fsio.norm(root)
  for _, path in ipairs(M.files(root, M.REPAIR_DIRS, names)) do
    local dir = fsio.dirname(path)
    local before = open_dirs(rootn, path)
    apply(path, function(text)
      return M.rewrite(text, dir, dir, {}, function(abs, l)
        if fsio.stat(abs) then
          return nil
        end
        -- a finished file's own link, written where it was open: what it named from there
        for _, d in ipairs(before) do
          local alt = mdlinks.resolve(d, l.target)
          if alt and fsio.stat(alt) then
            return alt
          end
        end
        if not abs:match("%.md$") then
          return nil
        end
        local name = abs:match("([^/]+)%.md$")
        local slug = name:gsub(DATE_PREFIX, "")
        local all = {}
        for _, c in ipairs(by_slug[slug] or {}) do
          if key(c) ~= key(path) then
            all[#all + 1] = c
          end
        end
        if #all == 0 then
          res.unresolved[#res.unresolved + 1] = { path = path, line = l.line, target = l.target }
          return nil
        end
        local area = key(abs):sub(#rootn + 2):match("^([^/]+)/")
        local near = {}
        for _, c in ipairs(all) do
          if area and key(c):sub(#rootn + 2):match("^([^/]+)/") == area then
            near[#near + 1] = c
          end
        end
        if #near == 1 then
          return near[1]
        elseif #all == 1 then
          return all[1]
        end
        res.ambiguous[#res.ambiguous + 1] =
          { path = path, line = l.line, target = l.target, candidates = all }
        return nil
      end)
    end, opts.dry_run == true, res)
  end
  return res
end

return M
