---@module 'tasks_nvim.contacts_io'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Contacts in and out: vCard (RFC 6350, versions 3.0 and 4.0) and CSV, offline, no account.
---@description
--- Reading turns a text into records (`name`, `org`, `role`, `emails`, `phones`, `tz`, `tags`, `notes`); nothing is
--- written by the readers. `import` makes contact files of the records through `contact_write.new`, `export` writes the
--- contacts of the vault as one text. The whole module is plain text in, plain text out: it opens no socket and asks no
--- service (decision D3/D4 of the Office concept: no sync with Google, Outlook or the system address book).
---
--- What does not fit is never dropped silently: a vCard property the contact has no field for (`ADR`, `BDAY`, `PHOTO`,
--- `X-...`) and a CSV column that is not known are named in `notes` of the record (the property or column NAME, never a
--- value). A mail address or phone number that is invalid, a time zone that is no `Area/City`, a missing name: the
--- record says which field and why, nothing else.
---
--- Duplicates: a record whose mail address (case does not matter) is held by a contact of the vault, or by an earlier
--- record of the same file, is not imported; the report names the record by its number and the id of the contact that
--- holds the address, never the address. An existing contact is never overwritten.
---
--- Personal data of third parties: no message of this module names a mail address or a phone number (`contacts.scrub`).
---
--- vCard written: `BEGIN:VCARD`, `VERSION:4.0` (or `3.0`), `FN`, `N`, `ORG`, `TITLE`, `EMAIL`, `TEL`, `TZ`, `NOTE`,
--- `CATEGORIES`, `END:VCARD`, CRLF line ends, lines folded at 75 octets (never inside a UTF-8 character).
--- CSV written: UTF-8, header `name,org,role,emails,phones,tz,tags,notes`, delimiter `,` (or what `delimiter` says), a
--- cell with several values joined by `;`, optional byte order mark (Excel wants it). CSV read: UTF-8 (a BOM is
--- removed; text that is no valid UTF-8 is refused), the delimiter is the one `,` `;` or tab that the header line has
--- most often unless `delimiter` is given, header names are case-insensitive and have aliases (`E-Mail`, `Company`...).
---
--- Not its job: the file choice of a UI, the vault write (`contact_write`), the CLI (`cli`).

local contacts = require("tasks_nvim.contacts")
local contact_write = require("tasks_nvim.contact_write")
local fsio = require("tasks_nvim.fsio")
local meetings = require("tasks_nvim.meetings")

local M = {}

---The header of the CSV this module writes.
M.CSV_COLUMNS = { "name", "org", "role", "emails", "phones", "tz", "tags", "notes" }

---The words a CSV header may use for a field (lower-case, blanks and `_` taken out).
M.CSV_ALIASES = {
  name = "name",
  fn = "name",
  fullname = "name",
  displayname = "name",
  org = "org",
  organization = "org",
  organisation = "org",
  company = "org",
  firma = "org",
  role = "role",
  title = "role",
  jobtitle = "role",
  position = "role",
  email = "emails",
  emails = "emails",
  ["e-mail"] = "emails",
  ["e-mailaddress"] = "emails",
  emailaddress = "emails",
  mail = "emails",
  phone = "phones",
  phones = "phones",
  tel = "phones",
  telephone = "phones",
  telefon = "phones",
  mobile = "phones",
  tz = "tz",
  timezone = "tz",
  zeitzone = "tz",
  tags = "tags",
  categories = "tags",
  category = "tags",
  kategorien = "tags",
  notes = "notes",
  note = "notes",
  notizen = "notes",
  notiz = "notes",
}

---vCard properties that carry no data of the person and are not worth a message.
local VCARD_QUIET =
  { BEGIN = true, END = true, VERSION = true, PRODID = true, REV = true, UID = true, N = true }

---Most records one file may hold, so a dump cannot make a million files.
M.MAX_RECORDS = 5000

---@class Tasks.ContactRecord
---@field name? string
---@field org? string
---@field role? string
---@field emails string[]
---@field phones string[]
---@field tz? string
---@field tags string[]
---@field notes string
---@field index integer   # 1-based number in the file
---@field problems string[]  # What was dropped or refused, as text without a mail or a number.
---@field fatal? boolean     # No usable name: the record cannot be imported.

local function new_record(index)
  return { emails = {}, phones = {}, tags = {}, notes = "", index = index, problems = {} }
end

---Whether `s` is valid UTF-8 (overlong forms, surrogates and values above U+10FFFF included).
---@param s string
---@return boolean
function M.is_utf8(s)
  if not s:find("[\128-\255]") then
    return true
  end
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

---Remove a byte order mark and make the line ends LF.
---@param text string
---@return string
local function normalize(text)
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  return (text:gsub("\r\n?", "\n"))
end

-- ── vCard ───────────────────────────────────────────────────────────────────

---Unfold the lines of a vCard (a line break followed by a blank continues the line).
---@param text string  # LF text
---@return string[]
local function unfold(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if (line:sub(1, 1) == " " or line:sub(1, 1) == "\t") and #out > 0 then
      out[#out] = out[#out] .. line:sub(2)
    else
      out[#out + 1] = line
    end
  end
  return out
end

---Split at the first `sep` that is not escaped with a backslash.
---@param s string
---@param sep string  # One character.
---@return string[]
local function split_escaped(s, sep)
  local out, cur, i = {}, {}, 1
  while i <= #s do
    local ch = s:sub(i, i)
    if ch == "\\" and i < #s then
      cur[#cur + 1] = s:sub(i, i + 1)
      i = i + 2
    elseif ch == sep then
      out[#out + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = ch
      i = i + 1
    end
  end
  out[#out + 1] = table.concat(cur)
  return out
end

---The text of a vCard value: `\n` a line break, `\,` `\;` `\\` the sign itself.
---@param s string
---@return string
local function unescape(s)
  return (
    s:gsub("\\(.)", function(c)
      if c == "n" or c == "N" then
        return "\n"
      end
      return c
    end)
  )
end

---The escaped text of a value for a vCard.
---@param s string
---@return string
local function escape(s)
  s = s:gsub("\\", "\\\\"):gsub(";", "\\;"):gsub(",", "\\,"):gsub("\r\n", "\n"):gsub("\n", "\\n")
  return s
end

---One content line: group, name, params, value. Nil when it has no colon.
---@param line string
---@return { name: string, params: string, value: string }|nil
local function split_line(line)
  -- the colon of the value is the first one outside quotes of a parameter
  local quoted, colon = false, nil
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == '"' then
      quoted = not quoted
    elseif ch == ":" and not quoted then
      colon = i
      break
    end
  end
  if not colon then
    return nil
  end
  local head, value = line:sub(1, colon - 1), line:sub(colon + 1)
  local semi = head:find(";", 1, true)
  local name = semi and head:sub(1, semi - 1) or head
  local params = semi and head:sub(semi + 1) or ""
  -- a group prefix: `item1.EMAIL`
  name = name:gsub("^[%w%-]+%.", "")
  return { name = name:upper(), params = params, value = value }
end

---The structured name `Family;Given;Additional;Prefix;Suffix` as `Given Family`.
---@param value string
---@return string|nil
local function name_from_n(value)
  local p = split_escaped(value, ";")
  local parts = {}
  for _, k in ipairs({ 4, 2, 3, 1, 5 }) do
    local t = vim.trim(unescape(p[k] or ""))
    if t ~= "" then
      parts[#parts + 1] = t
    end
  end
  return #parts > 0 and table.concat(parts, " ") or nil
end

---Read the vCards of a text.
---@param text string
---@return Tasks.ContactRecord[] records
---@return string[] messages   # About the file as a whole (an unsupported version, text outside a card).
function M.parse_vcf(text)
  text = normalize(text)
  local records, messages = {}, {}
  local cur, n_name
  local function finish()
    if not cur then
      return
    end
    if not cur.name and n_name then
      cur.name = n_name
    end
    if not cur.name then
      cur.fatal = true
      cur.problems[#cur.problems + 1] = "no FN (and no usable N): the card has no name"
    end
    cur.notes = vim.trim(cur.notes)
    records[#records + 1] = cur
    cur = nil
  end
  local unknown = {}
  local function flush_unknown()
    if cur and next(unknown) then
      local names = vim.tbl_keys(unknown)
      table.sort(names)
      cur.problems[#cur.problems + 1] = "not imported (no field for it): "
        .. table.concat(names, ", ")
    end
    unknown = {}
  end
  local stray = false
  for _, line in ipairs(unfold(text)) do
    if line ~= "" then
      local p = split_line(line)
      if not p then
        if cur then
          cur.problems[#cur.problems + 1] = "a line without a colon was skipped"
        else
          stray = true
        end
      elseif p.name == "BEGIN" and p.value:upper() == "VCARD" then
        if cur then
          flush_unknown()
          finish()
        end
        if #records >= M.MAX_RECORDS then
          messages[#messages + 1] = ("more than %d cards: the rest is not read"):format(
            M.MAX_RECORDS
          )
          cur = nil
          break
        end
        cur = new_record(#records + 1)
        n_name, unknown = nil, {}
      elseif not cur then
        stray = true
      elseif p.name == "END" and p.value:upper() == "VCARD" then
        flush_unknown()
        finish()
      else
        local enc = p.params:upper():find("ENCODING=QUOTED%-PRINTABLE") ~= nil
        local v = p.value
        if p.name == "VERSION" then
          local version = vim.trim(v)
          if version ~= "3.0" and version ~= "4.0" then
            cur.problems[#cur.problems + 1] = ("vCard version %s is read as 3.0 (3.0 and 4.0 are supported)"):format(
              fsio.clean(version):sub(1, 10)
            )
          end
        elseif enc then
          unknown[p.name] = true
          cur.problems[#cur.problems + 1] = "quoted-printable value of " .. p.name .. " is not read"
        elseif p.name == "FN" then
          local t = vim.trim(unescape(v))
          if t ~= "" and not cur.name then
            cur.name = t
          end
        elseif p.name == "N" then
          n_name = n_name or name_from_n(v)
        elseif p.name == "ORG" then
          local parts = {}
          for _, c in ipairs(split_escaped(v, ";")) do
            local t = vim.trim(unescape(c))
            if t ~= "" then
              parts[#parts + 1] = t
            end
          end
          if #parts > 0 and not cur.org then
            cur.org = table.concat(parts, " / ")
          end
        elseif p.name == "TITLE" then
          local t = vim.trim(unescape(v))
          if t ~= "" and not cur.role then
            cur.role = t
          end
        elseif p.name == "EMAIL" then
          local t = vim.trim(unescape(v)):gsub("^[mM][aA][iI][lL][tT][oO]:", "")
          if t ~= "" then
            cur.emails[#cur.emails + 1] = t
          end
        elseif p.name == "TEL" then
          local t = vim.trim(unescape(v)):gsub("^[tT][eE][lL]:", ""):gsub(";.*$", "")
          if t ~= "" then
            cur.phones[#cur.phones + 1] = t
          end
        elseif p.name == "TZ" then
          local t = vim.trim(unescape(v))
          if t ~= "" and not cur.tz then
            cur.tz = t
          end
        elseif p.name == "NOTE" then
          local t = vim.trim(unescape(v))
          if t ~= "" then
            cur.notes = cur.notes == "" and t or (cur.notes .. "\n\n" .. t)
          end
        elseif p.name == "CATEGORIES" then
          for _, c in ipairs(split_escaped(v, ",")) do
            local t = vim.trim(unescape(c))
            if t ~= "" then
              cur.tags[#cur.tags + 1] = t
            end
          end
        elseif not VCARD_QUIET[p.name] then
          unknown[p.name] = true
        end
      end
    end
  end
  if cur then
    flush_unknown()
    cur.problems[#cur.problems + 1] = "the card has no END:VCARD"
    finish()
  end
  if stray then
    messages[#messages + 1] = "text outside a BEGIN:VCARD ... END:VCARD block was skipped"
  end
  if #records == 0 then
    messages[#messages + 1] = "no vCard found"
  end
  return records, messages
end

---Fold a content line at 75 octets, never inside a UTF-8 character; the continuation starts with one blank.
---@param line string
---@return string
local function fold(line)
  if #line <= 75 then
    return line
  end
  local out, pos, limit = {}, 1, 75
  while pos <= #line do
    local stop = math.min(#line, pos + limit - 1)
    -- do not cut inside a multi-byte character: back off to the character start
    while
      stop < #line
      and stop > pos
      and line:byte(stop + 1) >= 0x80
      and line:byte(stop + 1) < 0xC0
    do
      stop = stop - 1
    end
    out[#out + 1] = line:sub(pos, stop)
    pos = stop + 1
    limit = 74
  end
  return table.concat(out, "\r\n ")
end

---The family and given name of a display name, for `N`: the last word is the family name.
---@param name string
---@return string
local function n_of(name)
  local given, family = name:match("^(.-)%s+(%S+)$")
  if not given then
    return escape(name) .. ";;;;"
  end
  return escape(family) .. ";" .. escape(given) .. ";;;"
end

---The vCard text of contacts.
---@param list Tasks.Contact[]
---@param opts? { version?: "3"|"4"|"3.0"|"4.0" }
---@return string
function M.write_vcf(list, opts)
  local v3 = opts and (opts.version == "3" or opts.version == "3.0")
  local out = {}
  local function put(s)
    out[#out + 1] = fold(s) .. "\r\n"
  end
  for _, c in ipairs(list) do
    put("BEGIN:VCARD")
    put("VERSION:" .. (v3 and "3.0" or "4.0"))
    put("FN:" .. escape(c.name))
    put("N:" .. n_of(c.name))
    if c.org then
      put("ORG:" .. escape(c.org))
    end
    if c.role then
      put("TITLE:" .. escape(c.role))
    end
    for _, e in ipairs(c.emails) do
      put((v3 and "EMAIL;TYPE=INTERNET:" or "EMAIL:") .. escape(e))
    end
    for _, p in ipairs(c.phones) do
      put("TEL:" .. escape(p))
    end
    if c.tz then
      put("TZ:" .. escape(c.tz))
    end
    if c.notes ~= "" then
      put("NOTE:" .. escape(c.notes))
    end
    if #c.tags > 0 then
      local t = {}
      for _, tag in ipairs(c.tags) do
        t[#t + 1] = escape(tag)
      end
      put("CATEGORIES:" .. table.concat(t, ","))
    end
    put("END:VCARD")
  end
  return table.concat(out)
end

-- ── CSV ─────────────────────────────────────────────────────────────────────

---The rows of a CSV text (RFC 4180: quotes, doubled quotes, line breaks inside a quoted cell).
---@param text string  # LF text
---@param delim string
---@return string[][]|nil rows
---@return string|nil err
local function csv_rows(text, delim)
  local rows, row, cell = {}, {}, {}
  local inq, i, n = false, 1, #text
  local function end_cell()
    row[#row + 1] = table.concat(cell)
    cell = {}
  end
  local function end_row()
    end_cell()
    -- a row of one empty cell is an empty line
    if not (#row == 1 and row[1] == "") then
      rows[#rows + 1] = row
    end
    row = {}
  end
  while i <= n do
    local ch = text:sub(i, i)
    if inq then
      if ch == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          cell[#cell + 1] = '"'
          i = i + 1
        else
          inq = false
        end
      else
        cell[#cell + 1] = ch
      end
    elseif ch == '"' and #cell == 0 then
      inq = true
    elseif ch == delim then
      end_cell()
    elseif ch == "\n" then
      end_row()
    else
      cell[#cell + 1] = ch
    end
    i = i + 1
  end
  if inq then
    return nil, "a quoted cell is not closed"
  end
  if #cell > 0 or #row > 0 then
    end_row()
  end
  return rows, nil
end

---The delimiter of a CSV: the one of `,` `;` tab the header line has most often (outside quotes), `,` on a tie.
---@param text string
---@return string
function M.detect_delimiter(text)
  local first = normalize(text):match("^[^\n]*") or ""
  local count = { [","] = 0, [";"] = 0, ["\t"] = 0 }
  local inq = false
  for ch in first:gmatch(".") do
    if ch == '"' then
      inq = not inq
    elseif not inq and count[ch] then
      count[ch] = count[ch] + 1
    end
  end
  local best, best_n = ",", count[","]
  for _, d in ipairs({ ";", "\t" }) do
    if count[d] > best_n then
      best, best_n = d, count[d]
    end
  end
  return best
end

local function header_key(h)
  return (h:lower():gsub("[%s_]", ""))
end

---Split a multi-value cell at `;` (or `,` when it has no `;`), blanks trimmed, empty parts dropped.
---@param cell string
---@return string[]
local function cell_list(cell)
  local sep = cell:find(";", 1, true) and ";" or ","
  local out = {}
  for part in (cell .. sep):gmatch("(.-)" .. vim.pesc(sep)) do
    local t = vim.trim(part)
    if t ~= "" then
      out[#out + 1] = t
    end
  end
  return out
end

---Whether a spreadsheet (Excel, LibreOffice, Sheets) would read a CSV cell as a formula: it starts, after
---blanks, with `=`, `+`, `-` or `@`, or with a tab or a carriage return. A `'` in front of such a start is
---itself a start that needs a guard, so that a value that really begins with `'=` comes back unchanged.
---@param s string
---@return boolean
local function formula_start(s)
  local rest = s:gsub("^ +", "")
  local first = rest:sub(1, 1)
  if first == "'" then
    return formula_start(rest:sub(2))
  end
  return first == "="
    or first == "+"
    or first == "-"
    or first == "@"
    or first == "\t"
    or first == "\r"
end

---The cell of a CSV that is text and never a formula: a value that starts like one gets a leading `'`.
---`unguard` is its exact inverse.
---@param s string
---@return string
local function guard(s)
  if formula_start(s) then
    return "'" .. s
  end
  return s
end

---Take the `'` away that `guard` (or a spreadsheet, which writes it for text typed with a leading `+`) put in front.
---@param s string
---@return string
local function unguard(s)
  if s:sub(1, 1) == "'" and formula_start(s:sub(2)) then
    return s:sub(2)
  end
  return s
end

---Read the records of a CSV text.
---@param text string
---@param opts? { delimiter?: string }
---@return Tasks.ContactRecord[]|nil records
---@return string[] messages  # The delimiter used, the columns not read; when `records` is nil, the reason.
function M.parse_csv(text, opts)
  opts = opts or {}
  if not M.is_utf8(text) then
    return nil, { "the file is not UTF-8 (save the CSV as UTF-8)" }
  end
  text = normalize(text)
  local delim = opts.delimiter
  if delim == "tab" then
    delim = "\t"
  end
  if delim ~= nil and delim ~= "," and delim ~= ";" and delim ~= "\t" then
    return nil, { "the delimiter must be , or ; or tab" }
  end
  delim = delim or M.detect_delimiter(text)
  local rows, err = csv_rows(text, delim)
  if not rows then
    return nil, { err }
  end
  local label = delim == "\t" and "tab" or delim
  local messages = { "delimiter: " .. label .. ", encoding: UTF-8" }
  if #rows == 0 then
    messages[#messages + 1] = "the CSV is empty (it needs a header line)"
    return {}, messages
  end
  local cols, ignored = {}, {}
  for ci, h in ipairs(rows[1]) do
    local field = M.CSV_ALIASES[header_key(h)]
    if field and not vim.tbl_contains(cols, field) then
      cols[ci] = field
    elseif vim.trim(h) ~= "" then
      ignored[#ignored + 1] = fsio.clean(vim.trim(h)):sub(1, 40)
    end
  end
  if not vim.tbl_contains(cols, "name") then
    return nil, { "the header has no name column (name, FN, full name)" }
  end
  if #ignored > 0 then
    messages[#messages + 1] = "columns not imported (no field for them): "
      .. table.concat(ignored, ", ")
  end
  if #rows - 1 > M.MAX_RECORDS then
    messages[#messages + 1] = ("more than %d rows: the rest is not read"):format(M.MAX_RECORDS)
  end
  local records = {}
  for ri = 2, math.min(#rows, M.MAX_RECORDS + 1) do
    local rec = new_record(#records + 1)
    for ci, cell in ipairs(rows[ri]) do
      local field = cols[ci]
      local t = unguard(vim.trim(cell))
      if field and t ~= "" then
        if field == "emails" or field == "phones" or field == "tags" then
          vim.list_extend(rec[field], cell_list(t))
        elseif field == "notes" then
          rec.notes = t
        else
          rec[field] = t
        end
      end
    end
    if not rec.name then
      rec.fatal = true
      rec.problems[#rec.problems + 1] = "no name in the row"
    end
    records[#records + 1] = rec
  end
  return records, messages
end

---The CSV text of contacts.
---@param list Tasks.Contact[]
---@param opts? { delimiter?: string, bom?: boolean, raw?: boolean }  # `raw`: no guard against spreadsheet formulas
---@return string
function M.write_csv(list, opts)
  opts = opts or {}
  local delim = opts.delimiter == "tab" and "\t" or opts.delimiter or ","
  local function cell(s)
    if not opts.raw then
      s = guard(s)
    end
    if s:find("[" .. vim.pesc(delim) .. '"\r\n]') then
      return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
  end
  local out = { opts.bom and "\239\187\191" or "" }
  out[#out + 1] = table.concat(M.CSV_COLUMNS, delim) .. "\r\n"
  for _, c in ipairs(list) do
    local row = {
      c.name,
      c.org or "",
      c.role or "",
      table.concat(c.emails, ";"),
      table.concat(c.phones, ";"),
      c.tz or "",
      table.concat(c.tags, ";"),
      (c.notes:gsub("\r\n", "\n")),
    }
    for i, v in ipairs(row) do
      row[i] = cell(v)
    end
    out[#out + 1] = table.concat(row, delim) .. "\r\n"
  end
  return table.concat(out)
end

-- ── import and export ───────────────────────────────────────────────────────

---The format of a file by its extension.
---@param path string
---@return "vcf"|"csv"|nil
function M.format_of(path)
  local ext = (path:match("%.([%w]+)$") or ""):lower()
  if ext == "vcf" or ext == "vcard" then
    return "vcf"
  elseif ext == "csv" or ext == "tsv" then
    return "csv"
  end
  return nil
end

---Clean the values of a record to what the contact file takes; what is refused goes into `problems`.
---@param rec Tasks.ContactRecord
---@return table fields
local function fields_of(rec)
  local f = {}
  local function text(key, v)
    if v and v ~= "" then
      f[key] = vim.trim(fsio.clean(v))
    end
  end
  text("org", rec.org)
  text("role", rec.role)
  local emails, phones, tags = {}, {}, {}
  local seen = {}
  for _, e in ipairs(rec.emails) do
    local key = e:lower()
    if not contacts.is_email(e) then
      rec.problems[#rec.problems + 1] = "an email address is invalid and was not imported"
    elseif not seen[key] then
      seen[key] = true
      emails[#emails + 1] = e
    end
  end
  for _, p in ipairs(rec.phones) do
    if contacts.is_phone(p) then
      phones[#phones + 1] = p
    else
      rec.problems[#rec.problems + 1] = "a phone number is invalid and was not imported"
    end
  end
  for _, t in ipairs(rec.tags) do
    t = vim.trim(fsio.clean(t))
    if t:find("[,%[%]\"'#]") then
      rec.problems[#rec.problems + 1] = "a tag with a quote, bracket, comma or # was not imported"
    elseif t ~= "" and not vim.tbl_contains(tags, t) then
      tags[#tags + 1] = t
    end
  end
  if #emails > contacts.MAX_LIST or #phones > contacts.MAX_LIST then
    rec.problems[#rec.problems + 1] = ("more than %d emails or phones: the rest was not imported"):format(
      contacts.MAX_LIST
    )
  end
  f.emails = vim.list_slice(emails, 1, contacts.MAX_LIST)
  f.phones = vim.list_slice(phones, 1, contacts.MAX_LIST)
  f.tags = vim.list_slice(tags, 1, contacts.MAX_LIST)
  if rec.tz and rec.tz ~= "" then
    if meetings.is_tz(rec.tz) then
      f.tz = rec.tz
    else
      rec.problems[#rec.problems + 1] = "tz is no time zone (Area/City or UTC) and was not imported"
    end
  end
  return f
end

---@class Tasks.ContactImportReport
---@field created { index: integer, id: string, name: string }[]   # With `dry_run`: what would be made.
---@field duplicates { index: integer, name: string, of: string }[]
---@field refused { index: integer, name?: string, reason: string }[]
---@field problems { index: integer, name?: string, text: string }[]
---@field messages string[]
---@field dry_run boolean

---Import records into an area. The vault is not touched with `dry_run`.
---@param area string
---@param records Tasks.ContactRecord[]
---@param opts { root?: string, today?: string, dry_run?: boolean, lang?: "de"|"en", messages?: string[] }
---@return Tasks.ContactImportReport|nil report
---@return string|nil err
function M.import_records(area, records, opts)
  local existing, errs = contacts.all({ root = opts.root })
  if not existing then
    return nil, contacts.scrub(tostring(errs))
  end
  local holder = {}
  for _, c in ipairs(existing) do
    for _, e in ipairs(c.emails) do
      holder[e:lower()] = holder[e:lower()] or c.id
    end
  end
  ---@type Tasks.ContactImportReport
  local rep = {
    created = {},
    duplicates = {},
    refused = {},
    problems = {},
    -- a note on the file can name what the file holds (a header cell of a CSV that is half data): scrubbed like the rest
    messages = vim.tbl_map(contacts.scrub, opts.messages or {}),
    dry_run = opts.dry_run == true,
  }
  local planned_slugs = {}
  local notes_heading = opts.lang == "en" and contacts.NOTES_HEADINGS[2]
    or contacts.NOTES_HEADINGS[1]
  for _, rec in ipairs(records) do
    local name = rec.name and vim.trim(fsio.clean(rec.name)) or nil
    local function note_problems()
      for _, t in ipairs(rec.problems) do
        rep.problems[#rep.problems + 1] =
          { index = rec.index, name = name, text = contacts.scrub(t) }
      end
    end
    if rec.fatal or not name or name == "" then
      note_problems()
      rep.refused[#rep.refused + 1] = { index = rec.index, name = name, reason = "no name" }
    else
      local fields = fields_of(rec)
      local dup
      for _, e in ipairs(fields.emails) do
        dup = holder[e:lower()]
        if dup then
          break
        end
      end
      if dup then
        note_problems()
        rep.duplicates[#rep.duplicates + 1] = { index = rec.index, name = name, of = dup }
      else
        local body
        if rec.notes ~= "" then
          body = "\n" .. notes_heading .. "\n\n" .. vim.trim(fsio.lf(rec.notes)) .. "\n"
        end
        local made, err, info = contact_write.new(area, {
          root = opts.root,
          today = opts.today,
          name = name,
          fields = fields,
          body = body,
          lang = opts.lang,
          dry_run = opts.dry_run,
          -- a dry run does not see the slugs of the records before it: keep them apart by hand
          slug = nil,
        })
        if not made then
          note_problems()
          rep.refused[#rep.refused + 1] = {
            index = rec.index,
            name = name,
            reason = contacts.scrub(tostring(err or (info and info.code) or "refused")),
          }
        else
          local id = made.id
          if opts.dry_run then
            local n = 1
            local base = made.slug
            while planned_slugs[id] do
              n = n + 1
              id = area .. "/" .. base .. "-" .. n
            end
            planned_slugs[id] = true
          end
          note_problems()
          rep.created[#rep.created + 1] = { index = rec.index, id = id, name = name }
          for _, e in ipairs(fields.emails) do
            holder[e:lower()] = id
          end
        end
      end
    end
  end
  return rep, nil
end

---Read a file and import it. `format` is `vcf` or `csv`; without it the extension decides.
---@param path string
---@param area string
---@param opts { root?: string, today?: string, dry_run?: boolean, lang?: "de"|"en", format?: string, delimiter?: string }
---@return Tasks.ContactImportReport|nil report
---@return string|nil err
function M.import_file(path, area, opts)
  local format = opts.format or M.format_of(path)
  if format ~= "vcf" and format ~= "csv" then
    return nil, "cannot tell the format of the file (.vcf or .csv, or --as=vcf|csv)"
  end
  local text, err = fsio.read(path)
  if not text then
    return nil, contacts.scrub("cannot read the file: " .. tostring(err))
  end
  local o = vim.tbl_extend("force", {}, opts)
  o.format = format
  return M.import_text(text, area, o)
end

---Import the text of a vCard or CSV file (what a page read from a file the person picked). `format` is `vcf` or `csv`.
---@param text string
---@param area string
---@param opts { root?: string, today?: string, dry_run?: boolean, lang?: "de"|"en", format: string, delimiter?: string }
---@return Tasks.ContactImportReport|nil report
---@return string|nil err
function M.import_text(text, area, opts)
  local format = opts.format
  if format ~= "vcf" and format ~= "csv" then
    return nil, "the format must be vcf or csv"
  end
  local records, messages
  if format == "vcf" then
    if not M.is_utf8(text) then
      return nil, "the file is not UTF-8"
    end
    records, messages = M.parse_vcf(text)
  else
    records, messages = M.parse_csv(text, { delimiter = opts.delimiter })
    if not records then
      return nil, table.concat(messages, "; ")
    end
  end
  local o = vim.tbl_extend("force", {}, opts)
  o.messages = messages
  return M.import_records(area, records, o)
end

---The contacts an export writes: the valid ones with the tag and of the organisation (case does not matter), by id.
---@param list Tasks.Contact[]
---@param opts? { tag?: string, org?: string }
---@return Tasks.Contact[]
function M.select(list, opts)
  opts = opts or {}
  local org = opts.org and tostring(opts.org):lower() or nil
  local kept = {}
  for _, c in ipairs(list) do
    local org_ok = org == nil or (c.org or ""):lower() == org
    local tag_ok = opts.tag == nil or vim.tbl_contains(c.tags, opts.tag)
    if c.valid and org_ok and tag_ok then
      kept[#kept + 1] = c
    end
  end
  table.sort(kept, function(a, b)
    return a.id < b.id
  end)
  return kept
end

---Export contacts as one text.
---@param list Tasks.Contact[]
---@param opts { format: string, version?: string, delimiter?: string, bom?: boolean, raw?: boolean }
---@return string|nil text
---@return string|nil err
function M.export(list, opts)
  if opts.format == "vcf" then
    if
      opts.version ~= nil
      and opts.version ~= "3"
      and opts.version ~= "4"
      and opts.version ~= "3.0"
      and opts.version ~= "4.0"
    then
      return nil, "the vCard version must be 3 or 4"
    end
    return M.write_vcf(list, { version = opts.version })
  elseif opts.format == "csv" then
    local d = opts.delimiter
    if d ~= nil and d ~= "," and d ~= ";" and d ~= "tab" and d ~= "\t" then
      return nil, "the delimiter must be , or ; or tab"
    end
    return M.write_csv(list, { delimiter = d, bom = opts.bom, raw = opts.raw })
  end
  return nil, "the format must be vcf or csv"
end

return M
