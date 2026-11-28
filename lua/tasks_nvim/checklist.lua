---@module 'tasks_nvim.checklist'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Checklists: lists of short entries without the weight of a task, several of them, with tags and attachments.
---@description
--- Every list is a folder of the vault root, `_list-<slug>/` (no area: its name starts with `_`); its name stands in
--- `_list-<slug>/list.md` (`title`, `created`). Every entry is a file of its own:
---
---     _list-support/list.md                                    the list
---     _list-support/20261125-204107-sap-ticket.md              a plain entry
---     _list-support/20261125-204107-sap-ticket/<same>.md       an entry with attachments (`assets/<kind>/...`)
---
--- An entry has the frontmatter `title`, `created` (`YYYY-MM-DDTHH:MM:SSZ`, the order of the list: newest first),
--- `done` (the day it was ticked; absent while open), `tags` and `updated`; its text is Markdown below. Its id is
--- `_list-<list>/<slug>`. It gets attachments the way a task does (`mutate.attach`, `board_save`: the plain file becomes
--- the folder form), and it can become a task of an area (`promote`): the task gets its title, text, tags and
--- attachments, and the entry is gone.
---
--- One file per entry, not one file per list: two devices adding at the same time never touch one file.
---
--- Not its job: the shape of a request (`ops`), the documents (`contract.checklists`, `contract.checklist`), copying an
--- attachment (`mutate.attach`).

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local uv = vim.uv or vim.loop

local M = {}

---The beginning of the folder name of a list; the folder name is the list's id.
M.PREFIX = "_list-"

---The file of a list's own data (its name) in its folder; no entry has this name.
M.LIST_FILE = "list.md"

---Longest title of a list or an entry, in bytes (the title limit of the documents).
M.MAX_TITLE = 300

---Longest part of a slug taken from a title.
M.MAX_SLUG_WORDS = 40

---Most entries one list may hold before `add` refuses (a runaway client, not a person).
M.MAX_ENTRIES = 2000

---Most lists of a vault.
M.MAX_LISTS = 200

---Most tags of one entry, and the longest tag.
M.MAX_TAGS = 20
M.MAX_TAG = 40

---@class Tasks.Checklist
---@field id string            # `_list-<slug>`
---@field slug string
---@field title string
---@field created string
---@field path string          # its `list.md`
---@field dir string
---@field etag string

---@class Tasks.ChecklistEntry
---@field id string            # `_list-<list>/<slug>`
---@field list string          # the id of its list
---@field slug string
---@field title string
---@field created string       # `YYYY-MM-DDTHH:MM:SSZ` (or what the file says when it says something else)
---@field done? string         # `YYYY-MM-DD`: ticked on that day
---@field tags string[]
---@field body string          # the text after the frontmatter, trimmed
---@field path string
---@field folder boolean
---@field etag string

-- ── names and ids ────────────────────────────────────────────────────────────

---The slug of a list id (`_list-<slug>`), or nil and why not.
---@param id any
---@return string|nil slug
---@return string|nil err
function M.list_slug(id)
  if type(id) ~= "string" or id:sub(1, #M.PREFIX) ~= M.PREFIX then
    return nil, "not a list: " .. fsio.clean(tostring(id))
  end
  local slug = id:sub(#M.PREFIX + 1)
  if not vault.valid_slug(slug) then
    return nil, "invalid list: " .. fsio.clean(id)
  end
  return slug, nil
end

---Whether `id` names an entry of a list (`_list-<list>/<slug>`; checked for its form only).
---@param id any
---@return boolean
function M.is_entry_id(id)
  return type(id) == "string" and id:sub(1, #M.PREFIX) == M.PREFIX and id:find("/", 1, true) ~= nil
end

---The list id and the slug of an entry id, or nil and why not.
---@param id any
---@return string|nil list
---@return string|nil slug_or_err
function M.split_id(id)
  if type(id) ~= "string" then
    return nil, "not an entry of a list: " .. fsio.clean(tostring(id))
  end
  local list, slug = id:match("^([^/]+)/([^/]+)$")
  if not list or not M.list_slug(list) then
    return nil, "not an entry of a list: " .. fsio.clean(id)
  end
  if not vault.valid_slug(slug) or slug .. ".md" == M.LIST_FILE then
    return nil, "invalid entry: " .. fsio.clean(id)
  end
  return list, slug
end

---The folder of list `list` (an id) in the vault at `root`.
---@param root string
---@param list string
---@return string
function M.dir(root, list)
  return root .. "/" .. list
end

-- ── lists ────────────────────────────────────────────────────────────────────

---A title as a list or an entry takes it: one line, not empty, not too long.
---@param title any
---@return string|nil title
---@return string|nil err
local function clean_title(title)
  if type(title) ~= "string" or title:find("[\r\n]") then
    return nil, "title must be one non-empty line"
  end
  local t = vim.trim(fsio.clean(title))
  if t == "" then
    return nil, "title must be one non-empty line"
  end
  if #t > M.MAX_TITLE then
    return nil, ("title is longer than %d bytes"):format(M.MAX_TITLE)
  end
  return t, nil
end

---The time stamp of `now` (seconds) as `created` holds it.
---@param now integer
---@return string
local function stamp(now)
  return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", now))
end

---@param s any
---@return boolean
local function is_stamp(s)
  return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil
end

---Read a list from the text of its `list.md`.
---@param root string
---@param slug string
---@param text string
---@return Tasks.Checklist
local function parse_list(root, slug, text)
  local parsed = fm.parse(text)
  local meta = parsed and parsed.has_block and parsed.meta or {}
  local title = type(meta.title) == "string" and vim.trim(meta.title) or ""
  local id = M.PREFIX .. slug
  return {
    id = id,
    slug = slug,
    title = title ~= "" and title or slug,
    created = type(meta.created) == "string" and meta.created or "",
    path = fsio.norm(M.dir(root, id) .. "/" .. M.LIST_FILE),
    dir = fsio.norm(M.dir(root, id)),
    etag = fsio.etag(text),
  }
end

---One list by id; a folder `_list-<slug>/` without its `list.md` is a list named by its slug.
---@param root string
---@param id string
---@return Tasks.Checklist|nil
---@return string|nil err
---@return table|nil info
function M.list(root, id)
  local slug, serr = M.list_slug(id)
  if not slug then
    return nil, serr, { code = "invalid_argument" }
  end
  local dir = M.dir(root, id)
  if not fsio.is_dir(dir) or fsio.is_link(dir) then
    return nil, "no list " .. id, { code = "not_found" }
  end
  local file = dir .. "/" .. M.LIST_FILE
  local text = fsio.is_file(file) and fsio.read(file) or ""
  return parse_list(root, slug, text or ""), nil
end

---Every list of the vault, by title (case folded), then id.
---@param root string
---@return Tasks.Checklist[]
function M.lists(root)
  local out = {}
  if not fsio.is_dir(root) then
    return out
  end
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" and name:sub(1, #M.PREFIX) == M.PREFIX then
      local l = M.list(root, name)
      if l then
        out[#out + 1] = l
      end
    end
  end
  table.sort(out, function(a, b)
    local at, bt = a.title:lower(), b.title:lower()
    if at ~= bt then
      return at < bt
    end
    return a.id < b.id
  end)
  return out
end

---Make a list: the folder `_list-<slug>/` and its `list.md`. The slug comes from the title (a taken one gets `-2`, ...);
---`opts.id` names it (then a taken id is an error: the inverse of `list_delete`).
---@param title string
---@param opts { root?: string, today?: string, now?: integer, id?: string, created?: string, dry_run?: boolean }
---@return { id: string, path: string }|nil
---@return string|nil err
---@return table|nil info
function M.list_new(title, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local t, terr = clean_title(title)
  if not t then
    return nil, terr, { code = "invalid_argument" }
  end
  local base
  if opts.id ~= nil then
    local s, serr = M.list_slug(opts.id)
    if not s then
      return nil, serr, { code = "invalid_argument" }
    end
    base = s
  else
    base = require("tasks_nvim.mutate").slugify(t, M.MAX_SLUG_WORDS)
  end
  local created = opts.created or stamp(opts.now or os.time())
  if not is_stamp(created) then
    return nil, "created must be YYYY-MM-DDTHH:MM:SSZ", { code = "invalid_argument" }
  end
  if #M.lists(root) >= M.MAX_LISTS then
    return nil,
      ("the vault holds %d lists already"):format(M.MAX_LISTS),
      { code = "payload_too_large" }
  end
  local text, ferr = fm.update_text(
    "\n",
    { { "title", t }, { "created", created }, { "updated", opts.today or model.today() } },
    { create = true }
  )
  if not text then
    return nil, "cannot build the list: " .. tostring(ferr)
  end
  for n = 1, 99 do
    local slug = n == 1 and base or (base .. "-" .. n)
    local id = M.PREFIX .. slug
    local dir = M.dir(root, id)
    local held = fsio.is_dir(dir) or fsio.is_file(dir)
    if held and opts.id then
      return nil, ("the list %s is there already"):format(id), { code = "exists" }
    end
    if not held then
      local path = fsio.norm(dir .. "/" .. M.LIST_FILE)
      if opts.dry_run then
        return { id = id, path = path }, nil
      end
      local made, merr = fsio.mkdirp(dir)
      if not made then
        return nil, ("cannot create %s: %s"):format(id, tostring(merr))
      end
      local ok, cerr = fsio.create_exclusive(path, text)
      if ok then
        return { id = id, path = path }, nil
      end
      if not fsio.is_exists(cerr) then
        return nil, ("cannot create %s: %s"):format(id, tostring(cerr))
      end
    end
  end
  return nil, "no free name for the list " .. base
end

---Rename a list (its `list.md`; made when the folder had none). The answer has the title before.
---What every writer of a list locks: the list's folder, so the lock file (`lib.nvim.fs.with_lock`:
---`._list-<slug>.lock`) lies beside the folder in the vault root, not in it. A folder that holds its own lock file
---cannot be removed under that lock, and an `add` waiting for it could then still fill the folder `list_delete` has
---just reported gone.
---@param l { dir: string }
---@return string
local function lock_target(l)
  return l.dir
end

---@param id string
---@param title string
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return { id: string, path: string, changed: boolean, before: string, etag_before: string, etag_after: string }|nil
---@return string|nil err
---@return table|nil info
function M.list_set(id, title, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local t, terr = clean_title(title)
  if not t then
    return nil, terr, { code = "invalid_argument" }
  end
  local l, lerr, linfo = M.list(root, id)
  if not l then
    return nil, lerr, linfo
  end
  if fsio.is_link(l.path) then
    return nil,
      id .. " is a symbolic link or junction: it is not written through",
      { code = "forbidden" }
  end
  local result
  local ok, err, info = fsio.with_lock(lock_target(l), function()
    if not fsio.is_dir(l.dir) then
      return nil, "no list " .. id, { code = "not_found" }
    end
    local cur = fsio.is_file(l.path) and fsio.read(l.path) or ""
    local etag = fsio.etag(cur or "")
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on"):format(id),
        { code = "conflict", id = id, expected = opts.if_match, actual = etag }
    end
    local before = parse_list(root, l.slug, cur or "")
    local text = cur
    if before.title ~= t then
      text = fm.update_text(
        cur ~= "" and cur or "\n",
        { { "title", t }, { "updated", opts.today or model.today() } },
        { create = true }
      )
      if not text then
        return nil, "cannot change " .. id
      end
    end
    result = {
      id = id,
      path = l.path,
      changed = text ~= cur,
      before = before.title,
      etag_before = etag,
      etag_after = fsio.etag(text),
    }
    if opts.dry_run or text == cur then
      return true
    end
    local wrote, werr = fsio.write_atomic(l.path, text)
    if not wrote then
      return nil, ("cannot write %s: %s"):format(id, tostring(werr))
    end
    return true
  end)
  if not ok then
    return nil, err, info
  end
  return result, nil
end

---Whether `name` is a file a system leaves in a folder (a hidden file, `desktop.ini`, `Thumbs.db`): no entry.
---@param name string
---@return boolean
local function system_file(name)
  local lower = name:lower()
  return name:sub(1, 1) == "." or lower == "desktop.ini" or lower == "thumbs.db"
end

---Whether `name` is a lock file of the list file (`lib.nvim.fs.with_lock`: `.list.md.lock`, `.list.md.lock.takeover`):
---where tasks.nvim before 2026-11-28 locked a list, inside its folder. One that a writer of that version holds belongs
---to its lock and is no entry.
---@param name string
---@return boolean
local function list_lock(name)
  return name == "." .. M.LIST_FILE .. ".lock" or name == "." .. M.LIST_FILE .. ".lock.takeover"
end

---Delete a list that holds no entries (an entry is never lost by deleting its list: delete the entries first).
---Check and removal, the folder included, run under the list's lock (`lock_target`, beside the folder), the one `add`
---takes before it creates an entry: an entry added at the same moment either comes first (the list holds it:
---`conflict`) or finds the list gone (`not_found`), never a folder with the entry, with or without its `list.md`.
---@param id string
---@param opts { root?: string, dry_run?: boolean, wait_ms?: integer }
---@return { id: string, path: string, title: string, created: string }|nil
---@return string|nil err
---@return table|nil info
function M.list_delete(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local l, lerr, linfo = M.list(root, id)
  if not l then
    return nil, lerr, linfo
  end
  local result
  local ok, err, info = fsio.with_lock(lock_target(l), function()
    if not fsio.is_dir(l.dir) then
      return nil, "no list " .. id, { code = "not_found" }
    end
    local leftovers = {}
    for name, kind in vim.fs.dir(l.dir) do
      if list_lock(name) then
        return nil, id .. " is locked by another writer", { code = "locked", retryable = true }
      end
      if name ~= M.LIST_FILE then
        if kind == "file" and system_file(name) then
          leftovers[#leftovers + 1] = l.dir .. "/" .. name
        else
          return nil, id .. " holds entries: delete them first", { code = "conflict", id = id }
        end
      end
    end
    if M._seam_delete_checked then
      -- the seam of the specs: another writer between the check and the removal
      M._seam_delete_checked(l)
    end
    result = { id = id, path = l.path, title = l.title, created = l.created }
    if opts.dry_run then
      return true
    end
    for _, path in ipairs(leftovers) do
      fsio.remove(path)
    end
    if fsio.is_file(l.path) then
      local removed, derr = fsio.remove(l.path)
      if not removed then
        return nil, ("cannot delete %s: %s"):format(id, tostring(derr))
      end
    end
    -- still under the lock (its file lies beside the folder): an `add` waiting for it finds the list gone
    local gone, gerr = uv.fs_rmdir(l.dir)
    if not gone then
      return nil, ("cannot delete %s: %s"):format(id, tostring(gerr))
    end
    return true
  end, { wait_ms = opts.wait_ms })
  if M._seam_delete_unlocked then
    -- the seam of the specs: another writer right after the lock was released
    M._seam_delete_unlocked(l)
  end
  if not ok then
    return nil, err, info
  end
  return result, nil
end

-- ── entries ──────────────────────────────────────────────────────────────────

---The file of entry `slug` of list `list`: the plain file or the folder form. Nil and why when it is not there (or both
---are).
---@param root string
---@param list string
---@param slug string
---@return string|nil path
---@return boolean|string folder  # the folder form; the error when there is no file
function M.resolve(root, list, slug)
  local dir = M.dir(root, list)
  local plain = dir .. "/" .. slug .. ".md"
  local folder_file = dir .. "/" .. slug .. "/" .. slug .. ".md"
  local has_plain, has_folder = fsio.is_file(plain), fsio.is_file(folder_file)
  if has_plain and has_folder then
    return nil, ("%s/%s exists as file and as folder"):format(list, slug)
  end
  if has_plain then
    return fsio.norm(plain), false
  end
  if has_folder then
    return fsio.norm(folder_file), true
  end
  return nil, ("no entry %s/%s"):format(list, slug)
end

---What `mutate.attach_target` answers for an entry: the file an attachment goes to and its folder form.
---@param id string
---@param root string
---@return table|nil target  # `{ id, area, slug, path, folder, file_kind = "checklist", folder_path }`
---@return string|nil err
function M.target(id, root)
  local list, slug = M.split_id(id)
  if not list then
    return nil, slug
  end
  ---@cast slug string
  local dir = M.dir(root, list)
  if fsio.is_link(dir) then
    return nil, list .. " is a symbolic link or junction: it is not written through"
  end
  local path, folder = M.resolve(root, list, slug)
  if not path then
    return nil, folder --[[@as string]]
  end
  return {
    id = list .. "/" .. slug,
    area = list,
    slug = slug,
    path = path,
    folder = folder == true,
    file_kind = "checklist",
    folder_path = fsio.norm(dir .. "/" .. slug .. "/" .. slug .. ".md"),
  },
    nil
end

---The tags of a frontmatter value: a list of words, lower case, each once.
---@param value any
---@return string[]
local function tags_of(value)
  local out, seen = {}, {}
  local items = type(value) == "table" and value or (type(value) == "string" and { value } or {})
  for _, item in ipairs(items) do
    if type(item) == "string" then
      local t = vim.trim(item):lower()
      if t ~= "" and not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
  end
  return out
end

---Read an entry from its text.
---@param text string
---@param ctx { list: string, slug: string, path: string, folder: boolean }
---@return Tasks.ChecklistEntry
function M.parse(text, ctx)
  local parsed = fm.parse(text)
  local meta = parsed and parsed.has_block and parsed.meta or {}
  local body = parsed and parsed.has_block and parsed.body or text
  local title = type(meta.title) == "string" and vim.trim(meta.title) or ""
  body = vim.trim(fsio.lf(body or ""))
  if title == "" then
    -- an entry written by hand without a title: its first line (a heading without its marks), else its slug
    title = vim.trim((body:match("^[^\n]*") or ""):gsub("^#+%s*", ""))
    if title == "" then
      title = ctx.slug
    end
  end
  local done = meta.done
  return {
    id = ctx.list .. "/" .. ctx.slug,
    list = ctx.list,
    slug = ctx.slug,
    title = title,
    created = type(meta.created) == "string" and meta.created or "",
    done = (type(done) == "string" and model.is_date(done)) and done or nil,
    tags = tags_of(meta.tags),
    body = body,
    path = ctx.path,
    folder = ctx.folder,
    etag = fsio.etag(text),
  }
end

---Every entry of list `list`, newest first (`created`, then the slug, both descending). A file that cannot be read is
---named in the second answer and left out.
---@param root string
---@param list string
---@return Tasks.ChecklistEntry[] entries
---@return string[] errors
function M.entries(root, list)
  local dir = M.dir(root, list)
  local out, errors = {}, {}
  if not fsio.is_dir(dir) or fsio.is_link(dir) then
    return out, errors
  end
  local seen = {}
  for name, kind in vim.fs.dir(dir) do
    local slug
    if kind == "file" and name:sub(-3) == ".md" and name ~= M.LIST_FILE then
      slug = name:sub(1, -4)
    elseif kind == "directory" then
      slug = name
    end
    if slug and vault.valid_slug(slug) and not seen[slug] then
      local path, f = M.resolve(root, list, slug)
      if path then
        seen[slug] = true
        local text, rerr = fsio.read(path)
        if text then
          out[#out + 1] =
            M.parse(text, { list = list, slug = slug, path = path, folder = f == true })
        else
          errors[#errors + 1] = ("cannot read %s/%s: %s"):format(list, slug, tostring(rerr))
        end
      elseif kind == "file" or fsio.is_file(dir .. "/" .. slug .. "/" .. slug .. ".md") then
        seen[slug] = true
        errors[#errors + 1] = tostring(f)
      end
    end
  end
  table.sort(out, function(a, b)
    if a.created ~= b.created then
      return a.created > b.created
    end
    return a.slug > b.slug
  end)
  return out, errors
end

---The ids of the entries of every list (`_list-<list>/<slug>`), sorted, each once, from the names in the list folders
---(a folder only when it holds `<slug>/<slug>.md`): no entry is read, only the `list.md` of each list (for a
---completion; `entries` reads them).
---@param root string
---@return string[]
function M.entry_ids(root)
  local ids, seen = {}, {}
  for _, l in ipairs(M.lists(root)) do
    for name, kind in vim.fs.dir(l.dir) do
      local slug
      if kind == "file" and name:sub(-3) == ".md" and name ~= M.LIST_FILE then
        slug = name:sub(1, -4)
      elseif kind == "directory" and fsio.is_file(l.dir .. "/" .. name .. "/" .. name .. ".md") then
        slug = name
      end
      local id = slug and l.id .. "/" .. slug
      if id and vault.valid_slug(slug) and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  table.sort(ids)
  return ids
end

---@class Tasks.ChecklistFilter
---@field since? string   # `YYYY-MM-DD`: made on that day or later
---@field until? string   # `YYYY-MM-DD`: made on that day or earlier
---@field tag? string     # carries this tag (case folded)
---@field q? string       # every word is in the title, the text or a tag (case folded)
---@field state? "open"|"done"|"all"

---The entries `f` lets through, in their order. The day of an entry is the date of its `created`; an entry without one
---(written by hand) is left out by `since` and `until`.
---@param entries Tasks.ChecklistEntry[]
---@param f Tasks.ChecklistFilter
---@return Tasks.ChecklistEntry[]
function M.filter(entries, f)
  local words = {}
  for w in ((f.q or ""):lower()):gmatch("%S+") do
    words[#words + 1] = w
  end
  local tag = f.tag and f.tag:lower() or nil
  local out = {}
  for _, e in ipairs(entries) do
    local day = e.created:match("^(%d%d%d%d%-%d%d%-%d%d)")
    local keep = true
    if f.state == "open" and e.done then
      keep = false
    elseif f.state == "done" and not e.done then
      keep = false
    end
    if keep and (f.since or f["until"]) then
      keep = day ~= nil
        and (f.since == nil or day >= f.since)
        and (f["until"] == nil or day <= f["until"])
    end
    if keep and tag then
      keep = vim.tbl_contains(e.tags, tag)
    end
    if keep and #words > 0 then
      local hay = (e.title .. "\n" .. e.body .. "\n" .. table.concat(e.tags, " ")):lower()
      for _, w in ipairs(words) do
        if not hay:find(w, 1, true) then
          keep = false
          break
        end
      end
    end
    if keep then
      out[#out + 1] = e
    end
  end
  return out
end

---One entry by id.
---@param id string
---@param root string
---@return Tasks.ChecklistEntry|nil
---@return string|nil err
---@return table|nil info
function M.find(id, root)
  local list, slug = M.split_id(id)
  if not list then
    return nil, slug, { code = "invalid_argument" }
  end
  ---@cast slug string
  local path, folder = M.resolve(root, list, slug)
  if not path then
    return nil, tostring(folder), { code = "not_found" }
  end
  local text, rerr = fsio.read(path)
  if not text then
    return nil, ("cannot read %s: %s"):format(id, tostring(rerr))
  end
  return M.parse(text, { list = list, slug = slug, path = path, folder = folder == true }), nil
end

---Check a list of tags: words of letters, digits, `_ . -` (no comma, bracket, quote or `#`), each at most `MAX_TAG`
---bytes, at most `MAX_TAGS`; lower case, each once.
---@param tags any
---@return string[]|nil
---@return string|nil err
function M.clean_tags(tags)
  if type(tags) ~= "table" then
    return nil, "tags must be a list of words"
  end
  local out, seen = {}, {}
  for _, t in ipairs(tags) do
    if type(t) ~= "string" then
      return nil, "tags must be a list of words"
    end
    local w = vim.trim(t):gsub("^#", ""):lower()
    if w ~= "" then
      if #w > M.MAX_TAG or not w:match("^[%w\128-\255][%w\128-\255_.%-]*$") then
        return nil, "a tag is a word of letters, digits, _ . - (at most " .. M.MAX_TAG .. " bytes)"
      end
      if not seen[w] then
        seen[w] = true
        out[#out + 1] = w
      end
    end
  end
  if #out > M.MAX_TAGS then
    return nil, ("an entry takes %d tags at most"):format(M.MAX_TAGS)
  end
  return out, nil
end

---The `#words` of a quickly typed line become tags: the line without them and the tags (`Ticket #sap #hiva` ->
---`Ticket`, `{ "sap", "hiva" }`). A `#` inside a word (`C#`, `issue#4`) stays text.
---@param line string
---@return string title
---@return string[] tags
function M.split_tags(line)
  local tags = {}
  local rest = (" " .. line .. " "):gsub("%s#([%w\128-\255][%w\128-\255_.%-]*)", function(word)
    tags[#tags + 1] = word
    return " "
  end)
  rest = vim.trim(rest:gsub("%s+", " "))
  return rest, tags
end

---Make an entry of list `list`. `#words` in the title become tags (`split_tags`), with `opts.tags`. Its slug is the time
---and the title (`20261125-204107-sap-ticket`), a taken one gets `-2`, ...; `opts.slug` names it (then a taken slug is
---an error). `opts.created` and `opts.done` carry an entry that is made again (the inverse of `delete`).
---@param list string
---@param title string
---@param opts { root?: string, today?: string, now?: integer, slug?: string, created?: string, done?: string, tags?: string[], body?: string, dry_run?: boolean, wait_ms?: integer }
---@return { id: string, slug: string, path: string, tags: string[] }|nil
---@return string|nil err
---@return table|nil info
function M.add(list, title, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local l, lerr, linfo = M.list(root, list)
  if not l then
    return nil, lerr, linfo
  end
  if type(title) ~= "string" then
    return nil, "title must be one non-empty line", { code = "invalid_argument" }
  end
  -- an entry made again (the inverse of `delete`, named by its slug) keeps its title: its tags come in `opts.tags`
  local line, from_line = title, {}
  if opts.slug == nil then
    line, from_line = M.split_tags(title)
  end
  local t, terr = clean_title(line)
  if not t then
    return nil, terr, { code = "invalid_argument" }
  end
  local all = vim.list_extend(vim.deepcopy(from_line), opts.tags or {})
  local tags, tgerr = M.clean_tags(all)
  if not tags then
    return nil, tgerr, { code = "invalid_argument" }
  end
  local today = opts.today or model.today()
  local created = opts.created or stamp(opts.now or os.time())
  if not is_stamp(created) then
    return nil, "created must be YYYY-MM-DDTHH:MM:SSZ", { code = "invalid_argument" }
  end
  if opts.done ~= nil and not model.is_date(opts.done) then
    return nil, "done must be a date (YYYY-MM-DD)", { code = "invalid_argument" }
  end
  local pairs_list = { { "title", t }, { "created", created } }
  if opts.done then
    pairs_list[#pairs_list + 1] = { "done", opts.done }
  end
  if #tags > 0 then
    pairs_list[#pairs_list + 1] = { "tags", tags }
  end
  pairs_list[#pairs_list + 1] = { "updated", today }
  local body = "\n"
  if type(opts.body) == "string" and vim.trim(opts.body) ~= "" then
    body = "\n" .. vim.trim(fsio.lf(opts.body)) .. "\n"
  end
  local text, ferr = fm.update_text(body, pairs_list, { create = true })
  if not text then
    return nil, "cannot build the entry: " .. tostring(ferr)
  end
  local base = opts.slug
  if base == nil then
    local words = require("tasks_nvim.mutate").slugify(t, M.MAX_SLUG_WORDS)
    base = created:gsub("[-:Z]", ""):gsub("T", "-"):lower() .. "-" .. words
  end
  local slug_err, details = vault.slug_error("slug", base)
  if slug_err then
    return nil, slug_err, { code = "invalid_argument", details = details }
  end
  if base .. ".md" == M.LIST_FILE then
    return nil, "slug 'list' is the list's own file", { code = "invalid_argument" }
  end
  if fsio.is_link(l.dir) then
    return nil,
      list .. " is a symbolic link or junction: it is not written through",
      { code = "forbidden" }
  end
  -- the list file existed when the list was read: gone under the lock means `list_delete` came first
  local had_file = fsio.is_file(l.path)
  local made
  local ok, err, info = fsio.with_lock(lock_target(l), function()
    -- `list_delete` removes the folder under this lock: gone now means it came first
    if not fsio.is_dir(l.dir) or (had_file and not fsio.is_file(l.path)) then
      return nil, "no list " .. list, { code = "not_found" }
    end
    local count = 0
    for name in vim.fs.dir(l.dir) do
      if list_lock(name) then
        return nil, list .. " is locked by another writer", { code = "locked", retryable = true }
      end
      count = count + 1
    end
    if count > M.MAX_ENTRIES then
      return nil,
        ("the list holds %d entries already"):format(M.MAX_ENTRIES),
        { code = "payload_too_large" }
    end
    for n = 1, 99 do
      local slug = n == 1 and base or (base .. "-" .. n)
      local path = l.dir .. "/" .. slug .. ".md"
      local held = fsio.is_file(path) or fsio.is_dir(l.dir .. "/" .. slug)
      if held and opts.slug then
        return nil, ("the id %s/%s is taken"):format(list, slug), { code = "exists" }
      end
      if not held then
        local result =
          { id = list .. "/" .. slug, slug = slug, path = fsio.norm(path), tags = tags }
        if opts.dry_run then
          made = result
          return true
        end
        local created_ok, cerr = fsio.create_exclusive(path, text)
        if created_ok then
          made = result
          return true
        end
        if not fsio.is_exists(cerr) then
          return nil, ("cannot create %s/%s: %s"):format(list, slug, tostring(cerr))
        end
      end
    end
    return nil, "no free file name for the entry " .. base
  end, { wait_ms = opts.wait_ms })
  if not ok then
    return nil, err, info
  end
  return made, nil
end

---Run `fn(entry, text)` under the lock of the entry's file, on the version `if_match` names.
---@param id string
---@param root string
---@param if_match? string
---@param fn fun(entry: Tasks.ChecklistEntry, text: string): any, string|nil, table|nil
---@return any
---@return string|nil err
---@return table|nil info
local function locked(id, root, if_match, fn)
  local found, ferr, finfo = M.find(id, root)
  if not found then
    return nil, ferr, finfo
  end
  if
    fsio.is_link(found.path)
    or fsio.is_link(M.dir(root, found.list))
    or (found.folder and fsio.is_link(fsio.dirname(found.path)))
  then
    return nil,
      id .. " is a symbolic link or junction: it is not written through",
      { code = "forbidden" }
  end
  return fsio.with_lock(found.path, function()
    local cur, rd_err = fsio.read(found.path)
    if not cur then
      return nil, ("cannot read %s: %s"):format(id, tostring(rd_err))
    end
    local etag = fsio.etag(cur)
    if if_match ~= nil and if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on (it is %s, the change was made on %s)"):format(
          found.id,
          etag,
          tostring(if_match)
        ),
        { code = "conflict", id = found.id, expected = if_match, actual = etag }
    end
    return fn(
      M.parse(
        cur,
        { list = found.list, slug = found.slug, path = found.path, folder = found.folder }
      ),
      cur
    )
  end)
end

---Change an entry: `patch.title` (one line), `patch.done` (true ticks it today, false opens it again), `patch.tags`
---(the whole list) and `patch.body` (its text). The answer has the values before (`before`) for an undo.
---@param id string
---@param patch { title?: string, done?: boolean, done_on?: string, tags?: string[], body?: string }
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return { id: string, path: string, changed: boolean, etag_before: string, etag_after: string, before: table }|nil
---@return string|nil err
---@return table|nil info
function M.set(id, patch, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if type(patch) ~= "table" or next(patch) == nil then
    return nil, "the patch is empty", { code = "invalid_argument" }
  end
  for key in pairs(patch) do
    if
      key ~= "title"
      and key ~= "done"
      and key ~= "done_on"
      and key ~= "tags"
      and key ~= "body"
    then
      return nil,
        ("unknown field '%s' (an entry takes: title, done, tags, body)"):format(
          fsio.clean(tostring(key))
        ),
        { code = "invalid_argument" }
    end
  end
  if patch.done ~= nil and type(patch.done) ~= "boolean" then
    return nil, "done must be true or false", { code = "invalid_argument" }
  end
  if patch.done_on ~= nil and (not model.is_date(patch.done_on) or patch.done == false) then
    return nil,
      "done_on must be a date (YYYY-MM-DD), not with done false",
      { code = "invalid_argument" }
  end
  if patch.body ~= nil and type(patch.body) ~= "string" then
    return nil, "body must be a text", { code = "invalid_argument" }
  end
  local title, tags
  if patch.title ~= nil then
    local terr
    title, terr = clean_title(patch.title)
    if not title then
      return nil, terr, { code = "invalid_argument" }
    end
  end
  if patch.tags ~= nil then
    local terr
    tags, terr = M.clean_tags(patch.tags)
    if not tags then
      return nil, terr, { code = "invalid_argument" }
    end
  end
  local today = opts.today or model.today()
  local result
  local ok, err, info = locked(id, root, opts.if_match, function(entry, cur)
    local list, before = {}, {}
    if title ~= nil and title ~= entry.title then
      list[#list + 1] = { "title", title }
      before.title = entry.title
    end
    -- `done_on` ticks it on that day; `done: true` ticks an open entry today and leaves a ticked one as it is
    local day = patch.done_on or (patch.done == true and entry.done == nil and today) or nil
    if day and entry.done ~= day then
      list[#list + 1] = { "done", day }
      before.done = entry.done or false
    elseif patch.done == false and entry.done ~= nil then
      list[#list + 1] = { "done", fm.REMOVE }
      -- the day it was ticked on, so that the way back ticks it on that day again
      before.done = entry.done
    end
    -- compared as text: the web variant runs this in a VM whose shim of `vim` has no `deep_equal`
    if tags ~= nil and table.concat(tags, " ") ~= table.concat(entry.tags, " ") then
      list[#list + 1] = { "tags", #tags > 0 and tags or fm.REMOVE }
      before.tags = entry.tags
    end
    local text = cur
    if #list > 0 then
      list[#list + 1] = { "updated", today }
      local new_text, uerr = fm.update_text(cur, list, { create = true })
      if not new_text then
        return nil, ("cannot change %s: %s"):format(id, tostring(uerr))
      end
      text = new_text
    end
    if patch.body ~= nil then
      local new_body = vim.trim(fsio.lf(patch.body))
      if new_body ~= entry.body then
        local parsed = fm.parse(text)
        local head = (parsed and parsed.has_block) and text:sub(1, #text - #parsed.body) or ""
        text = head .. "\n" .. (new_body ~= "" and (new_body .. "\n") or "")
        if #list == 0 then
          text = fm.update_text(text, { { "updated", today } }, { create = true }) or text
        end
        before.body = entry.body
      end
    end
    result = {
      id = entry.id,
      path = entry.path,
      changed = text ~= cur,
      etag_before = entry.etag,
      etag_after = fsio.etag(text),
      before = before,
    }
    if opts.dry_run or text == cur then
      return true
    end
    local wrote, werr = fsio.write_atomic(entry.path, text)
    if not wrote then
      return nil, ("cannot write %s: %s"):format(id, tostring(werr))
    end
    return true
  end)
  if not ok then
    return nil, err, info
  end
  return result, nil
end

---Whether `name` is a lock file of the entry file `own` (`lib.nvim.fs.with_lock`: `.<own>.lock`, `.<own>.lock.takeover`):
---held while the entry is written, it belongs to the lock and never to the entry's attachments.
---@param name string
---@param own string  # the file name of the entry
---@return boolean
local function own_lock(name, own)
  return name == "." .. own .. ".lock" or name == "." .. own .. ".lock.takeover"
end

---Everything below `dir`, deepest first, but the lock files of `own` beside it; nil and why when something there is a
---link (it is not followed).
---@param dir string
---@param own string  # the file name of the entry
---@return { path: string, dir: boolean }[]|nil
---@return string|nil err
local function tree_of(dir, own)
  local out = {}
  local function walk(d)
    for name in vim.fs.dir(d) do
      local p = d .. "/" .. name
      if d == dir and own_lock(name, own) then
        goto continue
      end
      local st = uv.fs_lstat(p)
      if not st or st.type == "link" or fsio.is_link(p) then
        return false
      end
      if st.type == "directory" then
        if not walk(p) then
          return false
        end
        out[#out + 1] = { path = p, dir = true }
      else
        out[#out + 1] = { path = p, dir = false }
      end
      ::continue::
    end
    return true
  end
  if not walk(dir) then
    return nil, "the folder of the entry holds a link: it is not deleted"
  end
  return out, nil
end

---Delete an entry with its attachments. The answer has what the entry held (`entry`, `had_assets`); an entry without
---attachments can be made again from it (`add` with its slug, `created`, `done`, tags and text).
---@param id string
---@param opts { root?: string, if_match?: string, dry_run?: boolean }
---@return { id: string, path: string, etag_before: string, entry: Tasks.ChecklistEntry, had_assets: boolean }|nil
---@return string|nil err
---@return table|nil info
function M.delete(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local result
  local ok, err, info = locked(id, root, opts.if_match, function(entry)
    local tree = {}
    if entry.folder then
      local t, terr = tree_of(fsio.dirname(entry.path), vim.fs.basename(entry.path))
      if not t then
        return nil, terr, { code = "forbidden" }
      end
      tree = t
    end
    local own = fsio.norm(entry.path)
    local had_assets = false
    for _, item in ipairs(tree) do
      if not item.dir and fsio.norm(item.path) ~= own then
        had_assets = true
      end
    end
    result = {
      id = entry.id,
      path = entry.path,
      etag_before = entry.etag,
      entry = entry,
      had_assets = had_assets,
    }
    if opts.dry_run then
      return true
    end
    -- the text last: a delete that stops half way leaves an entry (with fewer files), never files without one
    for _, item in ipairs(tree) do
      if fsio.norm(item.path) ~= own then
        local done, derr
        if item.dir then
          done, derr = uv.fs_rmdir(item.path)
        else
          done, derr = fsio.remove(item.path)
        end
        if not done then
          return nil, ("cannot delete a file of %s: %s"):format(id, tostring(derr))
        end
      end
    end
    local removed, derr = fsio.remove(entry.path)
    if not removed then
      return nil, ("cannot delete %s: %s"):format(id, tostring(derr))
    end
    return true
  end)
  if not ok then
    return nil, err, info
  end
  if result.entry.folder and not opts.dry_run then
    uv.fs_rmdir(fsio.dirname(result.entry.path))
  end
  return result, nil
end

---Make entry `id` a task of `area`: the task (`mutate.new`, a folder task when the entry has attachments) gets the
---entry's title, text and tags, the attachments move into the task's folder, then the entry is gone. A failure on the
---way takes the task back and leaves the entry as it was.
---@param id string
---@param area string
---@param opts { root?: string, today?: string, if_match?: string, lang?: "de"|"en", dry_run?: boolean }
---@return { id: string, from: string, path: string, moved: integer, area: string }|nil
---@return string|nil err
---@return table|nil info
function M.promote(id, area, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if type(area) ~= "string" or not vault.has_area(root, area) then
    return nil, "unknown area: " .. fsio.clean(tostring(area)), { code = "invalid_argument" }
  end
  local mutate = require("tasks_nvim.mutate")
  local result
  local folder_of_entry
  local ok, err, info = locked(id, root, opts.if_match, function(entry)
    local made, merr, minfo = mutate.new(area, {
      root = root,
      title = entry.title,
      today = opts.today,
      folder = entry.folder or nil,
      tags = #entry.tags > 0 and entry.tags or nil,
      body = entry.body ~= "" and entry.body or nil,
      lang = opts.lang,
      dry_run = opts.dry_run,
      index = false,
    })
    if not made then
      return nil, merr, minfo
    end
    result = { id = made.id, from = entry.id, path = made.path, moved = 0, area = area }
    if opts.dry_run then
      return true
    end
    -- the attachments: everything of the entry's folder but its text, into the folder of the task
    local moved = {}
    local function undo(why)
      for i = #moved, 1, -1 do
        fsio.rename(moved[i].to, moved[i].from)
      end
      fsio.remove(made.path)
      if entry.folder then
        uv.fs_rmdir(fsio.dirname(made.path))
      end
      return nil, why
    end
    if entry.folder then
      folder_of_entry = fsio.dirname(entry.path)
      local to_dir = fsio.dirname(made.path)
      local own = vim.fs.basename(entry.path)
      for name in vim.fs.dir(folder_of_entry) do
        if name ~= own and not own_lock(name, own) then
          local from, to = folder_of_entry .. "/" .. name, to_dir .. "/" .. name
          if fsio.is_link(from) then
            return undo(("%s holds a link: it is not moved"):format(id))
          end
          local mv, mverr = fsio.rename(from, to)
          if not mv then
            return undo(("cannot move the attachments of %s: %s"):format(id, tostring(mverr)))
          end
          moved[#moved + 1] = { from = from, to = to }
        end
      end
    end
    local removed, derr = fsio.remove(entry.path)
    if not removed then
      return undo(("cannot delete %s: %s"):format(id, tostring(derr)))
    end
    result.moved = #moved
    return true
  end)
  if not ok then
    return nil, err, info
  end
  if folder_of_entry then
    uv.fs_rmdir(folder_of_entry)
  end
  return result, nil
end

return M
