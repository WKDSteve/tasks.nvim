---@module 'tasks_nvim.path_draft'
-- @scans-data: the folders it lists (through `scan` and `check`) are task vaults, never the files of this plugin
---@brief A learning path from a whole draft: checked as `check` checks a path, written only when nothing is wrong.
---@description
--- `path-new <area> --from=<draft.md> [--dry-run]`: the draft is the whole file of the path (frontmatter, sections,
--- the tree of `## Lernpunkte`, `## Level`). It gets the slug `path-new` would give its title (or `--slug`), the
--- keys a new path always has when the draft leaves them out (`status: planning`, `created`, `updated`), and then
--- the findings of `check.path_file_findings` as if the file were already in place: keys, marks, XP, arrows,
--- relative links, levels, images. Any error or warning refuses the draft before anything is written; a hint
--- (`xp-missing`) does not. Every finding names the line of the draft and its code.
--- The hint `table-ragged` is the draft's own: a row of a table in `## Notiz im Detail` (the old wording of a note) with
--- more cells than its header, usually a pipe in code that Markdown split (`ls -l | less`).
---
--- Not its job (yet): promoting points of the draft to tasks, the operation of `tasks-ops/1`.

local check = require("tasks_nvim.check")
local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local paths = require("tasks_nvim.paths")
local plans = require("tasks_nvim.plans")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@class Tasks.PathDraftFinding
---@field code string
---@field severity "error"|"warn"|"info"
---@field line integer   # The line of the draft (1 for a fault of the frontmatter that names no key).
---@field message string

---@class Tasks.PathDraftResult
---@field id? string       # The id the path gets (absent when the draft has no title to make it of).
---@field path? string
---@field slug? string
---@field renamed? boolean # The slug asked for (or made of the title) was taken: `-2`, `-3`, … as `path-new`.
---@field findings Tasks.PathDraftFinding[]  # Errors and warnings: any of them refuses the draft.
---@field hints Tasks.PathDraftFinding[]
---@field written boolean
---@field dry_run boolean

---The lines before the body of `text` (its frontmatter block), or 0.
---@param text string
---@return integer
local function body_offset(text)
  local parsed = fm.parse(text)
  if not parsed or not parsed.has_block then
    return 0
  end
  local head = text:sub(1, #text - #(parsed.body or ""))
  return select(2, head:gsub("\n", ""))
end

---The line of the frontmatter key a fault of the file names ("status ...", "phase_order ..."), else 1.
---@param text string
---@param message string
---@return integer
local function key_line(text, message)
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n > 1 and line:match("^%-%-%-%s*$") then
      break
    end
    local key = n > 1 and line:match("^([%w_]+):")
    if key and message:find(key, 1, true) then
      return n
    end
  end
  return 1
end

---A finding of `check` as a finding of the draft: its line, and the lines its message names, moved from the filled text
---back to the draft (the keys added at the end of the frontmatter push the body down by `shift`).
---@param f Tasks.Finding
---@param draft string
---@param fm_end integer   # The last line of the draft's frontmatter block.
---@param shift integer
---@return Tasks.PathDraftFinding
local function draft_finding(f, draft, fm_end, shift)
  local function back(n)
    return n > fm_end + shift and n - shift or n
  end
  local message = f.message:gsub("line (%d+)", function(n)
    return "line " .. back(tonumber(n) --[[@as integer]])
  end)
  -- `line N: …`, or the first of the lines a hint lists (`… (line 8, 12): …`)
  local line = tonumber(message:match("^line (%d+):") or message:match("%(line (%d+)"))
  return {
    code = f.code,
    severity = f.severity,
    line = line or key_line(draft, f.message),
    message = message,
  }
end

---The number of cells of a table row: the pipes that are no escaped `\|`, without the outer ones.
---@param line string
---@return integer
local function cell_count(line)
  local body = vim.trim(line):gsub("^|", "")
  local n, i, bs = 1, 1, string.char(92)
  if body:sub(-1) == "|" and body:sub(-2, -2) ~= bs then
    body = body:sub(1, -2)
  end
  while i <= #body do
    local c = body:sub(i, i)
    if c == bs then
      i = i + 2
    else
      if c == "|" then
        n = n + 1
      end
      i = i + 1
    end
  end
  return n
end

---The rows of the tables of the section `## Notiz im Detail` (the old wording of a note) that have more cells than
---their header: a pipe in code (`ls -l | less`) splits a cell in Markdown unless it is written `\|`, so the row would
---land in the path as rubbish. A table is a row followed by a delimiter row (`| --- | --- |`); code fences are skipped.
---@param text string
---@return Tasks.PathDraftFinding[]
function M.ragged_rows(text)
  local out = {}
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  -- `pending`: a table row that may be a header (the delimiter row has to follow); `width`: the cells of the header of
  -- the table the lines are in (nil outside a table)
  local in_section, fence, pending, width = false, false, nil, nil
  for lnum, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence then
      local heading = line:match("^##%s+(.-)%s*$")
      if heading then
        in_section = heading:lower():find("^notiz im detail") ~= nil
        pending, width = nil, nil
      elseif in_section then
        if not line:match("^%s*|") then
          pending, width = nil, nil
        elseif line:match("^%s*|[%s:|-]+$") then
          width = pending and cell_count(pending) or width
          pending = nil
        elseif width then
          local n = cell_count(line)
          if n > width then
            out[#out + 1] = {
              code = "table-ragged",
              severity = "info",
              line = lnum,
              message = ("table row has %d cells, its header %d (a pipe inside code splits a cell: write it \\|)"):format(
                n,
                width
              ),
            }
          end
        else
          pending = line
        end
      end
    end
  end
  return out
end

---@param code string
---@param message string
---@return Tasks.PathDraftResult
local function refused(code, message)
  return {
    findings = { { code = code, severity = "error", line = 1, message = message } },
    hints = {},
    written = false,
    dry_run = false,
  }
end

---Check a draft of a learning path and write it to `<area>/ROADMAP/paths/<slug>.md` when nothing is wrong.
---@param area string
---@param draft string  # The whole file: frontmatter and body.
---@param opts { root?: string, today?: string, slug?: string, dry_run?: boolean }
---@return Tasks.PathDraftResult|nil result  # `findings` not empty: refused, nothing written.
---@return string|nil err                    # The call itself cannot run (no vault, no such area, a bad `slug`).
---@return table|nil info
function M.run(area, draft, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area)
  end
  local today = opts.today or model.today()
  local parsed = fm.parse(draft)
  if not parsed or not parsed.has_block then
    return refused("frontmatter-missing", "the draft has no frontmatter block (--- … ---)")
  end
  local title = parsed.meta.title
  if type(title) ~= "string" or vim.trim(title) == "" then
    return refused("title-missing", "the draft has no title: (title: … in the frontmatter)")
  end
  -- the slug `path-new` would give it; `plans.new` judges the title and `--slug` and writes nothing in a dry run
  local slot, serr, sinfo = paths.new(area, {
    root = root,
    today = today,
    title = title,
    slug = opts.slug,
    dry_run = true,
  })
  if not slot then
    return nil, serr, sinfo
  end
  local patch = {}
  for _, kv in ipairs({ { "status", "planning" }, { "created", today }, { "updated", today } }) do
    if parsed.meta[kv[1]] == nil then
      patch[#patch + 1] = kv
    end
  end
  local text = draft
  if #patch > 0 then
    local filled, ferr = fm.update_text(draft, patch)
    if not filled then
      return refused("frontmatter-invalid", "cannot complete the frontmatter: " .. tostring(ferr))
    end
    text = filled
  end
  local resolver = wikilinks.resolver(root)
  local scan_opts = { root = root, link_resolver = resolver }
  local file = paths.with_xp(
    plans.parse(text, {
      path = slot.path,
      area = area,
      slug = slot.slug,
      kind = "path",
      link_resolver = resolver,
    }),
    root
  )
  local open_ids = {}
  for _, a in ipairs(vault.areas(root)) do
    for _, t in ipairs(scan.area(a.name, scan_opts) or {}) do
      open_ids[t.id] = t
    end
  end
  local raw, raw_hints = {}, {}
  check.path_file_findings(raw, raw_hints, file, {
    open_ids = open_ids,
    is_finished = scan.finished_lookup(scan_opts),
    scan_opts = scan_opts,
    text = text,
  })
  local fm_end = body_offset(draft)
  local shift = body_offset(text) - fm_end
  local result = {
    id = slot.id,
    path = slot.path,
    slug = slot.slug,
    renamed = slot.renamed,
    findings = {},
    hints = {},
    written = false,
    dry_run = opts.dry_run == true,
  }
  for _, f in ipairs(raw) do
    result.findings[#result.findings + 1] = draft_finding(f, draft, fm_end, shift)
  end
  for _, f in ipairs(raw_hints) do
    result.hints[#result.hints + 1] = draft_finding(f, draft, fm_end, shift)
  end
  -- the hints of the draft itself, not of `check` (lines are those of the draft)
  vim.list_extend(result.hints, M.ragged_rows(draft))
  table.sort(result.findings, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.code < b.code
  end)
  if #result.findings > 0 or opts.dry_run then
    return result
  end
  local dir = vault.paths_dir(root, area)
  local mk_ok, mk_err = fsio.mkdirp(dir)
  if not mk_ok then
    return nil, "cannot create " .. dir .. ": " .. tostring(mk_err)
  end
  local ok, werr = fsio.create_exclusive(slot.path, text)
  if not ok then
    return nil, "cannot create " .. slot.path .. ": " .. tostring(werr)
  end
  result.written = true
  return result
end

return M
