---@module 'tasks_nvim.contact_write'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Writing contact files: make one, change its frontmatter, delete it.
---@description
--- Every change of an existing contact is read and written under the lock of its file, on the version the caller read
--- (`if_match`, else the version on disk), and it sets `updated`. A change that would make the file wrong (a mail address
--- that is none, a zone that is none) is refused with the words of `contacts.parse`; a fault the file had already is not
--- the change's. No message of this module names a mail address or a phone number (`contacts.scrub`).
---
--- Not its job: the shape of a request (`ops`), reading contacts (`contacts`), the rule check (`check`).

local contacts = require("tasks_nvim.contacts")
local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local meetings = require("tasks_nvim.meetings")
local model = require("tasks_nvim.model")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")

local M = {}

---The keys `new` takes in `fields` and `set` may change.
M.KEYS = contacts.KEYS

---Longest slug a contact gets from its name.
M.MAX_SLUG = 60

---The template of a new contact: the free text first, then the notes section.
---@param lang "de"|"en"
---@return string
function M.template_body(lang)
  return "\n" .. (lang == "en" and contacts.NOTES_HEADINGS[2] or contacts.NOTES_HEADINGS[1]) .. "\n"
end

---The frontmatter pairs of `fields` (keys of `M.KEYS`): a list value as a list, `nil`/`vim.NIL`/an empty value as
---removal. A value that cannot stand in the frontmatter is refused without naming it.
---@param fields table<string, any>
---@return table[]|nil pairs
---@return string|nil err
local function pairs_of(fields)
  local allowed = {}
  for _, k in ipairs(M.KEYS) do
    allowed[k] = true
  end
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    if not allowed[key] then
      return nil,
        ("unknown field '%s' (contacts take: %s)"):format(
          contacts.scrub(fsio.clean(tostring(key))),
          table.concat(M.KEYS, ", ")
        )
    end
    local value = fields[key]
    local remove = value == nil
      or value == vim.NIL
      or value == ""
      or (type(value) == "table" and #value == 0)
    if remove then
      if key == "name" then
        return nil, "name cannot be removed"
      end
      out[#out + 1] = { key, fm.REMOVE }
    elseif contacts.LIST_KEYS[key] then
      local items = type(value) == "table" and value
        or vim.split(tostring(value), ",", { plain = true })
      local list = {}
      for _, item in ipairs(items) do
        if type(item) ~= "string" then
          return nil, key .. " must be a list of texts"
        end
        local t = vim.trim(item)
        if t:find("[,%[%]\"'#\r\n]") then
          return nil, key .. " entries must not contain , [ ] quotes # or a line break"
        end
        if t ~= "" then
          list[#list + 1] = t
        end
      end
      if #list > contacts.MAX_LIST then
        return nil, ("%s takes %d entries at most"):format(key, contacts.MAX_LIST)
      end
      out[#out + 1] = { key, list }
    else
      if type(value) ~= "string" then
        return nil, key .. " must be a text"
      end
      local t = vim.trim(value)
      if t:find("[\r\n]") then
        return nil, key .. " must be one line"
      end
      out[#out + 1] = { key, t }
    end
  end
  return out, nil
end

---The error codes `after` has and `before` had not: what a change brings.
---@param before Tasks.Contact
---@param after Tasks.Contact
---@return string|nil message
local function new_fault(before, after)
  local known = {}
  for _, code in ipairs(before.error_codes) do
    known[code] = true
  end
  for i, code in ipairs(after.error_codes) do
    if not known[code] then
      return after.errors[i]
    end
  end
  return nil
end

---@class Tasks.ContactEdit
---@field id string
---@field area string
---@field path string
---@field changed boolean
---@field etag_before? string
---@field etag_after? string
---@field before? table   # `set`: the old values of the keys it changed.

---Change a contact file under its lock. `transform(text, contact)` gives the new text (or nil and an error); `updated`
---is set when the text changed. Refused when the file is not the version `opts.if_match` names (`conflict`) or when the
---change brings a fault (`invalid_argument`).
---@param id string
---@param transform fun(text: string, contact: Tasks.Contact): string|nil, string|nil
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return Tasks.ContactEdit|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict"|"forbidden" }`
local function edit(id, transform, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local found, ferr = contacts.find(id, { root = root })
  if not found then
    return nil, ferr, { code = "not_found" }
  end
  if fsio.is_link(found.path) then
    return nil,
      id .. " is a symbolic link or junction: it is not written through",
      { code = "forbidden" }
  end
  local today = opts.today or model.today()
  local result = { id = found.id, area = found.area, path = found.path, changed = false }
  local ok, werr, winfo = fsio.with_lock(found.path, function()
    local cur, rd_err = fsio.read(found.path)
    if not cur then
      return nil, "cannot read " .. found.id .. ": " .. contacts.scrub(tostring(rd_err))
    end
    local etag = fsio.etag(cur)
    result.etag_before, result.etag_after = etag, etag
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on (it is %s, the change was made on %s)"):format(
          found.id,
          etag,
          tostring(opts.if_match)
        ),
        { code = "conflict", id = found.id, expected = opts.if_match, actual = etag }
    end
    local ctx = { path = found.path, area = found.area, slug = found.slug, folder = found.folder }
    local before = contacts.parse(cur, ctx)
    local text, terr = transform(cur, before)
    if not text then
      return nil, terr or "the change cannot be made", { code = "invalid_argument" }
    end
    if text ~= cur then
      text = fm.update_text(text, { { "updated", today } }) or text
      local fault = new_fault(before, contacts.parse(text, ctx))
      if fault then
        return nil, fault, { code = "invalid_argument" }
      end
    end
    result.changed = text ~= cur
    result.etag_after = fsio.etag(text)
    if opts.dry_run or not result.changed then
      return true
    end
    local wrote, wr_err = fsio.write_atomic(found.path, text)
    if not wrote then
      return nil, "cannot write " .. found.id .. ": " .. contacts.scrub(tostring(wr_err))
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  return result, nil
end

---The slug a contact gets: the name folded (`mutate.slugify`).
---@param name string
---@return string
function M.slug_of(name)
  return require("tasks_nvim.mutate").slugify(name, M.MAX_SLUG)
end

---Make a contact file `<area>/CONTACTS/<slug>.md`. `fields` are the keys of `M.KEYS`; `name` is needed (the `name`
---option, or `fields.name`); `body` is the free text (else the template with the notes heading); `slug` overrides the
---one of the name (then a taken slug is an error, else it gets `-2`, `-3`, ...). A dry run names the id it would get.
---@param area string
---@param opts { root?: string, today?: string, name?: string, fields?: table, body?: string, slug?: string, lang?: "de"|"en", dry_run?: boolean }
---@return { id: string, path: string, slug: string, renamed: boolean }|nil result
---@return string|nil err
---@return table|nil info
function M.new(area, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if not vault.has_area(root, area) then
    return nil,
      "unknown area: " .. contacts.scrub(fsio.clean(tostring(area))),
      { code = "invalid_argument" }
  end
  local fields = vim.deepcopy(opts.fields or {})
  local name = opts.name or fields.name
  -- the line break is looked for first: `clean` turns it into a blank
  if type(name) == "string" and name:find("[\r\n]") then
    return nil, "name must be one non-empty line", { code = "invalid_argument" }
  end
  name = type(name) == "string" and vim.trim(fsio.clean(name)) or ""
  if name == "" then
    return nil, "name must be one non-empty line", { code = "invalid_argument" }
  end
  fields.name = name
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD)"
  end
  local list, perr = pairs_of(fields)
  if not list then
    return nil, perr, { code = "invalid_argument" }
  end
  local by_key = {}
  for _, kv in ipairs(list) do
    if kv[2] ~= fm.REMOVE then
      by_key[kv[1]] = kv[2]
    end
  end
  local ordered = {}
  for _, key in ipairs(M.KEYS) do
    if by_key[key] ~= nil then
      ordered[#ordered + 1] = { key, by_key[key] }
    end
  end
  ordered[#ordered + 1] = { "created", today }
  ordered[#ordered + 1] = { "updated", today }
  local body
  if opts.body ~= nil then
    body = "\n" .. vim.trim(fsio.lf(opts.body)) .. "\n"
  else
    body = M.template_body(opts.lang == "en" and "en" or "de")
  end
  local text, ferr = fm.update_text(body, ordered, { create = true })
  if not text then
    return nil, "cannot build the contact file: " .. contacts.scrub(tostring(ferr))
  end

  local base = opts.slug or M.slug_of(name)
  local slug_err, slug_details = vault.slug_error("slug", base)
  if slug_err then
    return nil, slug_err, { code = "invalid_argument", details = slug_details }
  end
  if vault.is_reserved_name(base) then
    return nil,
      ("slug '%s' is a reserved Windows device name"):format(base),
      { code = "invalid_argument" }
  end
  -- judged as the file would read: a bad mail address, a bad number, a bad zone
  local probe = contacts.parse(text, { path = base .. ".md", area = area, slug = base })
  if not probe.valid then
    return nil, probe.errors[1], { code = "invalid_argument" }
  end

  local dir = vault.contacts_dir(root, area)
  if not opts.dry_run then
    local made, mkerr = fsio.mkdirp(dir)
    if not made then
      return nil,
        "cannot create the contact folder of " .. area .. ": " .. contacts.scrub(tostring(mkerr))
    end
  end
  local backlog_taken, berr = scan.backlog_slugs(area, { root = root })
  if not backlog_taken then
    return nil, berr
  end
  for n = 1, 999 do
    local slug = n == 1 and base or (base .. "-" .. n)
    local path = dir .. "/" .. slug .. ".md"
    -- tasks, plans, projects, meetings and contacts share one id namespace
    local held = backlog_taken[slug] ~= nil
      or fsio.is_file(vault.task_path(root, area, slug))
      or fsio.is_dir(vault.task_dir(root, area, slug))
      or vault.has_plan_or_project(root, area, slug)
      or vault.resolve_meeting(root, area, slug) ~= nil
      or fsio.is_dir(dir .. "/" .. slug)
      or fsio.is_file(path)
      -- an occurrence of a series without a file holds its id as well
      or meetings.occurrence(root, area, slug) ~= nil
    if held and opts.slug then
      return nil, ("the id %s/%s is taken"):format(area, slug), { code = "exists" }
    end
    if not held then
      local result = { id = area .. "/" .. slug, path = path, slug = slug, renamed = n > 1 }
      if opts.dry_run then
        return result, nil
      end
      local ok, cerr = fsio.create_exclusive(path, text)
      if ok then
        return result, nil
      end
      if not fsio.is_exists(cerr) then
        return nil,
          "cannot create the contact " .. area .. "/" .. slug .. ": " .. contacts.scrub(
            tostring(cerr)
          )
      end
    end
  end
  return nil, "no free file name for contact " .. base
end

---Change the frontmatter of a contact. `patch` maps keys of `M.KEYS` to their new value (`nil`, `vim.NIL` or an empty
---value removes one; not `name`). The answer has the old values (`before`) for an undo.
---@param id string
---@param patch table<string, any>
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return (Tasks.ContactEdit|{ before: table })|nil
---@return string|nil
---@return table|nil
function M.set(id, patch, opts)
  if type(patch) ~= "table" or next(patch) == nil then
    return nil, "the patch is empty", { code = "invalid_argument" }
  end
  local before = {}
  local r, err, info = edit(id, function(text)
    local list, perr = pairs_of(patch)
    if not list then
      return nil, perr
    end
    local parsed = fm.parse(text)
    for _, kv in ipairs(list) do
      local old = parsed and parsed.has_block and fm.get(parsed, kv[1]) or nil
      before[kv[1]] = old == nil and vim.NIL or old
    end
    local new_text, uerr = fm.update_text(text, list)
    if not new_text then
      return nil, "cannot change " .. id .. ": " .. contacts.scrub(tostring(uerr))
    end
    return new_text
  end, opts)
  if not r then
    return nil, err, info
  end
  r.before = before
  return r, nil
end

---@class Tasks.ContactDelete
---@field id string
---@field area string
---@field slug string
---@field path string
---@field etag_before string
---@field contact Tasks.Contact   # What the file held: the inverse makes it again.

---Delete a contact file under its lock, on the version `opts.if_match` names. A contact in the folder form is deleted
---with its folder only when the file is all the folder holds (an attachment is never lost by a delete).
---@param id string
---@param opts { root?: string, if_match?: string, dry_run?: boolean }
---@return Tasks.ContactDelete|nil
---@return string|nil err
---@return table|nil info
function M.delete(id, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local found, ferr = contacts.find(id, { root = root })
  if not found then
    return nil, ferr, { code = "not_found" }
  end
  if fsio.is_link(found.path) then
    return nil, id .. " is a symbolic link or junction: it is not deleted", { code = "forbidden" }
  end
  if found.folder then
    local dir = vim.fs.dirname(found.path)
    for name in vim.fs.dir(dir) do
      if name ~= found.slug .. ".md" then
        return nil, id .. " has files attached: delete them first", { code = "conflict", id = id }
      end
    end
  end
  local result = { id = found.id, area = found.area, slug = found.slug, path = found.path }
  local ok, werr, winfo = fsio.with_lock(found.path, function()
    local cur, rd_err = fsio.read(found.path)
    if not cur then
      return nil, "cannot read " .. found.id .. ": " .. contacts.scrub(tostring(rd_err))
    end
    local etag = fsio.etag(cur)
    result.etag_before = etag
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the delete was made on (it is %s, the delete was made on %s)"):format(
          found.id,
          etag,
          tostring(opts.if_match)
        ),
        { code = "conflict", id = found.id, expected = opts.if_match, actual = etag }
    end
    result.contact = contacts.parse(
      cur,
      { path = found.path, area = found.area, slug = found.slug, folder = found.folder }
    )
    if opts.dry_run then
      return true
    end
    local removed, err = fsio.remove(found.path)
    if not removed then
      return nil, "cannot delete " .. found.id .. ": " .. contacts.scrub(tostring(err))
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  if found.folder and not opts.dry_run then
    -- the empty folder of the folder form goes with its file
    (vim.uv or vim.loop).fs_rmdir(vim.fs.dirname(found.path))
  end
  return result, nil
end

return M
