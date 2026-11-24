---@module 'tasks_nvim.contacts'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Contact files: one Markdown file per person under `<area>/CONTACTS/`.
---@description
--- A contact is not a task: it has no status, no priority and no readiness. Its file is `<area>/CONTACTS/<slug>.md`, or
--- `<area>/CONTACTS/<slug>/<slug>.md` once something was attached to it. The id is `<area>/<slug>` and shares the
--- namespace of the area with the tasks, plans, projects, meetings and paths. A contact lives in any area: nothing asks
--- whether the vault may hold personal data of others (decision D3 of the Office concept).
---
--- Frontmatter (flat YAML): `name` (needed), `org`, `role`, `emails`, `phones`, `tz` (an IANA zone, only its form),
--- `tags`, `created`, `updated`. The body is free text; the section `## Notizen` / `## Notes` is read apart as `notes`.
---
--- What a contact holds is personal data of third parties. The contract never names a mail address or a phone number in
--- an error text, a log line or a note: the messages of this module say which field is wrong, never its value, and
--- `scrub` takes the two out of any text that came from elsewhere (the frontmatter parser quotes the line it
--- stumbles on).
---
--- Not its job: writing (`contact_write`, `ops`), the rule check across files (`check`), the documents (`contract`).

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local meetings = require("tasks_nvim.meetings")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---The keys `new` takes in `fields` and `set` may change. `name` cannot be removed.
---@type string[]
M.KEYS = { "name", "org", "role", "emails", "phones", "tz", "tags" }

---The keys whose value is a list.
M.LIST_KEYS = { emails = true, phones = true, tags = true }

---Most entries of `emails`, `phones` and `tags`.
M.MAX_LIST = 20

---The words of the notes section, German first.
M.NOTES_HEADINGS = { "## Notizen", "## Notes" }

---What replaces a mail address or a phone number in a text (`scrub`).
M.REDACTED = "<redacted>"

---Whether `s` is a mail address in the form the engine accepts: one `@`, no blanks or list syntax, a dot in the domain.
---@param s any
---@return boolean
function M.is_email(s)
  if type(s) ~= "string" or #s > 254 then
    return false
  end
  local at = s:find("@", 1, true)
  if not at or at == 1 or s:find("@", at + 1, true) then
    return false
  end
  if s:find("[%s<>,%[%]\"'#]") then
    return false
  end
  local domain = s:sub(at + 1)
  return domain:match("^[^%.]+%..*[^%.]$") ~= nil and not domain:find("..", 1, true)
end

---Whether `s` is a phone number the engine accepts: digits with `+` first, blanks, `-`, `/`, `.` and brackets between
---(seven digits at least, 15 at most as E.164 has them, 30 characters at most).
---@param s any
---@return boolean
function M.is_phone(s)
  if type(s) ~= "string" or #s > 30 or s:find("[^%d%s%+%-%./%(%)]") then
    return false
  end
  if s:find("+", 2, true) then
    return false
  end
  local digits = #s:gsub("%D", "")
  return digits >= 7 and digits <= 15
end

---Take mail addresses and phone numbers out of a text: what a message of the contract may say about a contact.
---@param text string
---@return string
function M.scrub(text)
  text = tostring(text)
  -- a mail address: everything around an `@` up to the next blank or bracket
  text = text:gsub("[%w%.%%%+%-_]*@[%w%.%-_]+", M.REDACTED)
  -- what has digits but is no number of a person stays: the version tag of a file (`sha256:` and 16 hex digits, a
  -- conflict names two) and a calendar day
  local kept = {}
  local function keep(s)
    kept[#kept + 1] = s
    return "\1" .. #kept .. "\1"
  end
  text = text:gsub("sha256:%x+", keep)
  text = text:gsub("%d%d%d%d%-%d%d%-%d%d", keep)
  -- a phone number: seven digits at least, with the signs a number is written with
  text = text:gsub("%+?[%d%(][%d%s%-%./%(%)]*%d", function(run)
    if #run:gsub("%D", "") >= 7 then
      return M.REDACTED
    end
    return run
  end)
  text = text:gsub("\1(%d+)\1", function(n)
    return kept[tonumber(n)]
  end)
  return text
end

---@class Tasks.Contact
---@field id string
---@field area string
---@field slug string
---@field path string
---@field folder boolean
---@field name string
---@field org? string
---@field role? string
---@field emails string[]
---@field phones string[]
---@field tz? string
---@field tags string[]
---@field created? string
---@field updated? string
---@field summary string
---@field notes string
---@field body string
---@field errors string[]
---@field error_codes string[]
---@field valid boolean
---@field etag? string

---Read one contact file's text. Always returns a contact; a broken file carries `errors` (`valid = false`), none of
---which names a mail address or a phone number.
---@param text string
---@param ctx { path: string, area: string, slug?: string, folder?: boolean }
---@return Tasks.Contact
function M.parse(text, ctx)
  local slug = ctx.slug or vim.fs.basename(ctx.path):gsub("%.md$", "")
  local errors, codes = {}, {}
  local function bad(code, msg)
    errors[#errors + 1] = M.scrub(msg)
    codes[#codes + 1] = code
  end
  ---@type Tasks.Contact
  local c = {
    id = ctx.area .. "/" .. slug,
    area = ctx.area,
    slug = slug,
    path = fsio.norm(ctx.path),
    folder = ctx.folder == true,
    name = slug,
    emails = {},
    phones = {},
    tags = {},
    summary = "",
    notes = "",
    body = "",
    errors = errors,
    error_codes = codes,
    valid = false,
  }
  if not vault.valid_slug(slug) then
    bad("slug", "filename is not a kebab-case ASCII slug: " .. fsio.clean(slug))
  end
  local parsed, perr = fm.parse(text)
  if not parsed then
    bad("frontmatter-missing", "frontmatter unreadable: " .. tostring(perr))
    return c
  elseif not parsed.has_block then
    bad("frontmatter-missing", "no frontmatter block")
    return c
  end
  local meta = parsed.meta
  local name = model.field_text(meta.name, "name", bad)
  if not name then
    bad("contact-name-missing", "name is missing")
  else
    c.name = name
  end
  c.org = model.field_text(meta.org, "org", bad)
  c.role = model.field_text(meta.role, "role", bad)

  c.emails = model.field_list(meta.emails, "emails", bad)
  for i, e in ipairs(c.emails) do
    if not M.is_email(e) then
      bad("contact-bad-email", ("emails[%d] is no mail address"):format(i))
    end
  end
  c.phones = model.field_list(meta.phones, "phones", bad)
  for i, p in ipairs(c.phones) do
    if not M.is_phone(p) then
      bad("contact-bad-phone", ("phones[%d] is no phone number"):format(i))
    end
  end
  if #c.emails > M.MAX_LIST or #c.phones > M.MAX_LIST then
    bad("contact-too-many", ("emails and phones take %d entries at most"):format(M.MAX_LIST))
  end
  local tz = model.field_text(meta.tz, "tz", bad)
  if tz then
    if meetings.is_tz(tz) then
      c.tz = tz
    else
      bad("contact-bad-tz", "tz is no time zone (Area/City or UTC): " .. fsio.clean(tz))
    end
  end
  c.tags = model.field_list(meta.tags, "tags", bad)
  local created = model.field_text(meta.created, "created", bad)
  c.created = model.is_date(created) and created or nil
  local updated = model.field_text(meta.updated, "updated", bad)
  c.updated = model.is_date(updated) and updated or nil

  local body = parsed.body or ""
  c.body = body
  c.summary = model.first_paragraph(body)
  c.notes = M.notes_of(body)
  c.valid = #errors == 0
  return c
end

---The text below `## Notizen` (or `## Notes`) up to the next heading of that level, trimmed.
---@param body string
---@return string
function M.notes_of(body)
  local out, inside = {}, false
  for _, line in ipairs(vim.split((body:gsub("\r\n", "\n")), "\n", { plain = true })) do
    local head = line:match("^(##%s.-)%s*$")
    if head then
      inside = vim.tbl_contains(M.NOTES_HEADINGS, head)
    elseif inside then
      out[#out + 1] = line
    end
  end
  return vim.trim(table.concat(out, "\n"))
end

---Read one contact file from disk. An unreadable file or a link yields an invalid contact, never a raise.
---@param path string
---@param ctx { area: string, slug?: string, folder?: boolean }
---@return Tasks.Contact
function M.from_file(path, ctx)
  local full = vim.tbl_extend("force", { path = path }, ctx)
  if fsio.is_link(path) then
    local c = M.parse("", full)
    c.errors = {
      "the contact file is a symbolic link or junction; it is not read (the vault must not point outside itself)",
    }
    c.error_codes = { "symlink-task" }
    c.valid = false
    return c
  end
  local text, err = fsio.read(path)
  if not text then
    local c = M.parse("", full)
    c.errors = { "cannot read file: " .. M.scrub(tostring(err)) }
    c.error_codes = { "unreadable" }
    c.valid = false
    return c
  end
  local c = M.parse(text, full)
  c.etag = fsio.etag(text)
  return c
end

---The contact files of an area, by slug.
---@param area string
---@param opts? { root?: string }
---@return Tasks.Contact[]|nil contacts
---@return string[]|string|nil errors
function M.area(area, opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  if not vault.valid_area(area) then
    return nil, "invalid area name: " .. tostring(area)
  end
  local dir = vault.contacts_dir(root, area)
  local out = {}
  if not fsio.is_dir(dir) then
    return out, {}
  end
  local escape = vault.leaves(root, dir)
  if escape then
    return out, { escape }
  end
  for _, e in ipairs(vault.plan_files(dir)) do
    out[#out + 1] = M.from_file(e.path, { area = area, slug = e.slug, folder = e.folder })
  end
  return out, {}
end

---Every contact of the vault, areas in name order, and the folders that could not be read.
---@param opts? { root?: string }
---@return Tasks.Contact[]|nil contacts
---@return string[]|string|nil errors
function M.all(opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local out, errors = {}, {}
  for _, a in ipairs(vault.areas(root)) do
    local list, errs = M.area(a.name, { root = root })
    vim.list_extend(out, list or {})
    for _, e in ipairs(type(errs) == "table" and errs or {}) do
      errors[#errors + 1] = e
    end
  end
  return out, errors
end

---A contact by id.
---@param id string
---@param opts? { root?: string }
---@return Tasks.Contact|nil contact
---@return string|nil err
function M.find(id, opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local area, slug, id_err = vault.parse_id(id)
  if not area or not slug then
    return nil, id_err or ("expected <area>/<slug>, got " .. tostring(id))
  end
  if not vault.has_area(root, area) then
    return nil, "no such contact: " .. id
  end
  if vault.leaves(root, vault.contacts_dir(root, area)) then
    return nil, "no such contact: " .. id
  end
  local path, folder = vault.resolve_contact(root, area, slug)
  if not path then
    return nil, folder --[[@as string]]
  end
  return M.from_file(path, { area = area, slug = slug, folder = folder == true }), nil
end

return M
