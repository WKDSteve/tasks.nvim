---@module 'tasks_nvim.competences'
---@brief The competences of a vault: one file per field of knowledge in `<area>/ROADMAP/competences/<slug>.md`, its
---stage in theory and practice, its targets, and the learning paths that name it.
---@description
--- A competence file:
---
---     ---
---     title: "Betriebssysteme"
---     group: "Informatik-Kern"
---     t: 3              # the stage in theory, 0..8, halves allowed (3.5); `?` or absent: not assessed yet
---     p: 1              # the stage in practice
---     target_12: 4      # the target in 12 months: one stage for both, or {t: 4, p: 4.5}
---     target_24: 4.5    # the target in 24 months
---     assessed: 2026-10-29
---     ---
---     Why, and the next evidence (text).
---
--- A learning path names its field with `competence: <area>/<slug>` (or a list) and may say what it aims at with
--- `competence_target: {t: 4, p: 4}` (or one stage). The frontmatter reader of lib.nvim keeps no maps, so a map
--- (`{t: 4, p: 4}`, also as a quoted text, the form `path_set` writes) is read here from its line.
---
--- The scale (`SCALE`) is the one of the Kompetenzmatrix: 0 Unbekannt … 8 Mastermind, in German or English.
---
--- A field the file does not know is a problem (`competence-unknown-field`), as are a stage outside 0..8 or not in
--- halves (`competence-bad-level`), a target that is neither (`competence-bad-target`) and a date that is none
--- (`bad-date`). Read only; no I/O but reading the files.

-- @scans-data

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")

local M = {}

---The highest stage.
M.MAX_LEVEL = 8

---The names of the stages 0..8, by language.
M.SCALE = {
  de = {
    "Unbekannt",
    "Newbie",
    "Fortgeschritten",
    "Profi",
    "Bachelor",
    "Master",
    "Doctor",
    "Professor",
    "Mastermind",
  },
  en = {
    "Unknown",
    "Newbie",
    "Advanced",
    "Professional",
    "Bachelor",
    "Master",
    "Doctor",
    "Professor",
    "Mastermind",
  },
}

---The fields a competence file knows.
M.FIELDS =
  { "title", "group", "t", "p", "target_12", "target_24", "assessed", "created", "updated" }

---@class Tasks.CompetenceTarget
---@field t? number
---@field p? number

---@class Tasks.Competence
---@field id string
---@field area string
---@field slug string
---@field path string
---@field title string
---@field group? string
---@field t? number
---@field p? number
---@field target_12? Tasks.CompetenceTarget
---@field target_24? Tasks.CompetenceTarget
---@field assessed? string
---@field body string
---@field errors string[]
---@field error_codes string[]
---@field valid boolean

---The folder of the competences of an area.
---@param root string
---@param area string
---@return string
function M.dir(root, area)
  return root .. "/" .. area .. "/ROADMAP/competences"
end

---A stage as written (`3`, `3.5`, `3,5`, a number): 0..8 in halves; nil and false for anything else, nil and nil for
---`?` (not assessed).
---@param v any
---@return number|nil level
---@return boolean|nil bad
function M.level_of(v)
  if type(v) == "number" then
    v = tostring(v)
  end
  if type(v) ~= "string" then
    return nil, true
  end
  local t = vim.trim(v):gsub(",", ".")
  if t == "?" then
    return nil, nil
  end
  if not (t:match("^%d$") or t:match("^%d%.%d$")) then
    return nil, true
  end
  local n = tonumber(t)
  if not n or n < 0 or n > M.MAX_LEVEL or (n * 2) ~= math.floor(n * 2) then
    return nil, true
  end
  return n == math.floor(n) and math.floor(n) or n, nil
end

---A target as written: one stage for both axes (`4`), or `{t: 4, p: 4.5}` (either key may be left out); nil and the
---reason for anything else.
---@param v any
---@return Tasks.CompetenceTarget|nil
---@return string|nil err
function M.target_of(v)
  if type(v) == "number" then
    v = tostring(v)
  end
  if type(v) ~= "string" then
    return nil, "a target is a stage (0..8) or {t: N, p: N}"
  end
  local text = vim.trim(v)
  local inner = text:match("^{(.*)}$")
  if not inner then
    local n, bad = M.level_of(text)
    if not n or bad then
      return nil,
        "a target is a stage 0..8 in halves or {t: N, p: N}, not '" .. fsio.clean(text) .. "'"
    end
    return { t = n, p = n }
  end
  local out = {}
  for part in (inner .. ","):gmatch("([^,]*),") do
    part = vim.trim(part)
    if part ~= "" then
      local k, val = part:match("^(%a+)%s*:%s*(.-)$")
      if (k ~= "t" and k ~= "p") or out[k] ~= nil then
        return nil, "a target map takes t and p once each, not '" .. fsio.clean(part) .. "'"
      end
      local n, bad = M.level_of(val)
      if not n or bad then
        return nil, "the stage of " .. k .. " is 0..8 in halves, not '" .. fsio.clean(val) .. "'"
      end
      out[k] = n
    end
  end
  if out.t == nil and out.p == nil then
    return nil, "an empty target"
  end
  return out
end

---The value of a key as written: the reader's text, else the rest of its line when the reader left it as a shape it
---does not keep (a map).
---@param parsed table  # `lib.nvim.markdown.frontmatter.parse`
---@param key string
---@return any
function M.raw_value(parsed, key)
  local v = parsed.meta and parsed.meta[key]
  if v ~= nil then
    return v
  end
  for _, e in ipairs(parsed.entries or {}) do
    if e.key == key and e.opaque and type(e.raw) == "string" then
      return (e.raw:match("^[^:]*:%s*(.-)%s*$"))
    end
  end
  return nil
end

---The text without the line of `key` when the frontmatter reader kept it as a line only (a map it does not read);
---the text as it is otherwise. Its line ending goes with it.
---@param text string
---@param parsed table  # `lib.nvim.markdown.frontmatter.parse` of `text`
---@param key string
---@return string
function M.drop_opaque(text, parsed, key)
  for _, e in ipairs(parsed.entries or {}) do
    if e.key == key and e.opaque and type(e.line) == "number" then
      local out, n, pos = {}, 0, 1
      while pos <= #text do
        local nl = text:find("\n", pos, true)
        local stop = nl or #text
        n = n + 1
        if n ~= e.line then
          out[#out + 1] = text:sub(pos, stop)
        end
        pos = stop + 1
      end
      return table.concat(out)
    end
  end
  return text
end

---The keys a frontmatter block names, in file order.
---@param parsed table
---@return string[]
local function keys_of(parsed)
  local out = {}
  for _, e in ipairs(parsed.entries or {}) do
    if e.key then
      out[#out + 1] = e.key
    end
  end
  return out
end

---Read one competence file's text. Always returns a competence; a broken file carries `errors` (`valid = false`).
---@param text string
---@param ctx { path: string, area: string, slug?: string }
---@return Tasks.Competence
function M.parse(text, ctx)
  local slug = ctx.slug or model.slug_of(ctx.path, "roadmap")
  local errors, codes = {}, {}
  local function bad(code, msg)
    errors[#errors + 1] = msg
    codes[#codes + 1] = code
  end
  ---@type Tasks.Competence
  local c = {
    id = ctx.area .. "/" .. slug,
    area = ctx.area,
    slug = slug,
    path = fsio.norm(ctx.path),
    title = slug,
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
  elseif not parsed.has_block then
    bad("frontmatter-missing", "no frontmatter block")
  else
    local meta = parsed.meta
    c.body = parsed.body or ""
    for _, key in ipairs(keys_of(parsed)) do
      if not vim.tbl_contains(M.FIELDS, key) then
        bad(
          "competence-unknown-field",
          ("unknown field '%s' (known: %s)"):format(fsio.clean(key), table.concat(M.FIELDS, ", "))
        )
      end
    end
    c.title = model.field_text(meta.title, "title", bad) or slug
    if meta.title == nil then
      bad("title-missing", "title is missing")
    end
    c.group = model.field_text(meta.group, "group", bad)
    for _, axis in ipairs({ "t", "p" }) do
      local raw = M.raw_value(parsed, axis)
      if raw ~= nil then
        local n, wrong = M.level_of(raw)
        if wrong then
          bad(
            "competence-bad-level",
            ("%s '%s' is no stage 0..8 in halves (or ? for not assessed)"):format(
              axis,
              fsio.clean(tostring(raw))
            )
          )
        end
        if axis == "t" then
          c.t = n
        else
          c.p = n
        end
      end
    end
    for _, key in ipairs({ "target_12", "target_24" }) do
      local raw = M.raw_value(parsed, key)
      if raw ~= nil then
        local target, terr = M.target_of(raw)
        if target then
          c[key] = target
        else
          bad("competence-bad-target", key .. ": " .. tostring(terr))
        end
      end
    end
    for _, field in ipairs({ "assessed", "created", "updated" }) do
      local date = model.field_text(meta[field], field, bad)
      if date then
        if model.is_date(date) then
          if field == "assessed" then
            c.assessed = date
          end
        else
          bad("bad-date", ("%s '%s' is not a date (YYYY-MM-DD)"):format(field, fsio.clean(date)))
        end
      end
    end
  end
  c.valid = #errors == 0
  return c
end

---Read one competence file from disk.
---@param path string
---@param ctx { area: string, slug?: string }
---@return Tasks.Competence
function M.from_file(path, ctx)
  local text, err = fsio.read(path)
  local c = vim.tbl_extend("force", { path = path }, ctx)
  if not text then
    local out = M.parse("", c)
    out.errors = { "cannot read the file: " .. tostring(err) }
    out.error_codes = { "unreadable" }
    out.valid = false
    return out
  end
  return M.parse(text, c)
end

---The competences of an area, by slug.
---@param area string
---@param opts? { root?: string }
---@return Tasks.Competence[]|nil competences
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
  local dir = M.dir(root, area)
  local out = {}
  if not fsio.is_dir(dir) then
    return out, {}
  end
  local escape = vault.leaves(root, dir)
  if escape then
    return out, { escape }
  end
  for _, e in ipairs(vault.plan_files(dir)) do
    if not e.folder then
      out[#out + 1] = M.from_file(e.path, { area = area, slug = e.slug })
    end
  end
  return out, {}
end

---Every competence of the vault, areas in name order.
---@param opts? { root?: string }
---@return Tasks.Competence[]|nil competences
---@return string|nil err
function M.all(opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local out = {}
  for _, a in ipairs(vault.areas(root)) do
    vim.list_extend(out, M.area(a.name, { root = root }) or {})
  end
  return out, nil
end

---The ids of the competences of a vault, as a set.
---@param root string
---@return table<string, boolean>
function M.ids(root)
  return fsio.scope_memo("competence-ids:" .. root, function()
    local out = {}
    for _, c in ipairs(M.all({ root = root }) or {}) do
      out[c.id] = true
    end
    return out
  end)
end

---Read what a path says of its competence (`competence`, `competence_target`) into `plan`; a malformed value is a
---problem of the file (`path-bad-competence`). Whether an id names a competence is `check`'s (`competence-unknown`).
---@param parsed table  # The frontmatter of the path (`lib.nvim.markdown.frontmatter.parse`).
---@param plan table
---@param bad fun(code: string, msg: string)
function M.read_path(parsed, plan, bad)
  local meta = parsed.meta or {}
  local value = meta.competence
  if value ~= nil then
    local list = type(value) == "table" and value or { value }
    local ids = {}
    for _, id in ipairs(list) do
      local a, s, e = vault.parse_id(type(id) == "string" and vim.trim(id) or "")
      if a and s and not e then
        if not vim.tbl_contains(ids, a .. "/" .. s) then
          ids[#ids + 1] = a .. "/" .. s
        end
      else
        bad(
          "path-bad-competence",
          "competence: expected <area>/<slug>, got '" .. fsio.clean(tostring(id)) .. "'"
        )
      end
    end
    plan.competence = #ids > 0 and ids or nil
  end
  local raw = M.raw_value(parsed, "competence_target")
  if raw ~= nil then
    local target, terr = M.target_of(raw)
    if target then
      plan.competence_target = target
    else
      bad("path-bad-competence", "competence_target: " .. tostring(terr))
    end
  end
end

---A target as `competence_target` writes it: `{t: 4, p: 4.5}`.
---@param target Tasks.CompetenceTarget
---@return string
function M.render_target(target)
  local parts = {}
  for _, axis in ipairs({ "t", "p" }) do
    if target[axis] ~= nil then
      parts[#parts + 1] = ("%s: %s"):format(axis, ("%g"):format(target[axis]))
    end
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

---The scale in a language (`de`, else `en`): `{ level, name }` for 0..8.
---@param lang? string
---@return { level: integer, name: string }[]
function M.scale(lang)
  local names = M.SCALE[lang == "en" and "en" or "de"]
  local out = {}
  for i, name in ipairs(names) do
    out[#out + 1] = { level = i - 1, name = name }
  end
  return out
end

return M
