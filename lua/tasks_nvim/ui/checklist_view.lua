---@module 'tasks_nvim.ui.checklist_view'
---@brief `:Tasks checklist ...`: the checklists of the vault (`_list-<slug>/`) in the editor: pick one, show its entries,
---add, tick, delete, filter, make a task of one, open one as a file.
---@description
--- A thin layer over `tasks_nvim.checklist`: the entries are read and filtered there (`entries`, `filter`), every write
--- goes through the write door (`tasks_nvim.ops`: `checklist_new`, `entry_add`, `entry_set`, `entry_delete`,
--- `entry_promote`), so the editor does what tasks-desktop and the CLI do. A list is a scratch buffer of its own
--- (`tasks-checklist://<id>`, one per list), newest entry first, a ticked one dimmed; its keys are buffer-local
--- (`keys.checklist`, help on `g?`). Each write names the version it read (`if_match`): an entry changed on another
--- device in between is refused, not overwritten.
---
--- Not its job: reading or writing the files of a list (`checklist`), the shape of a request (`ops`).

local checklist = require("tasks_nvim.checklist")
local model = require("tasks_nvim.model")
local vault = require("tasks_nvim.vault")
local nul_safe = require("lib.lua.strings.core").nul_safe
local notify = require("lib.nvim.notify").create("[tasks]")

local M = {}

---The beginning of the name of a list's buffer.
M.SCHEME = "tasks-checklist://"

---The lines above the first entry (title, filter, blank).
M.HEAD = 3

---The states the state key cycles through, in order.
M.STATES = { "all", "open", "done" }

local NS = vim.api.nvim_create_namespace("tasks_checklist")

---@class Tasks.ChecklistView.State
---@field list string                          # the list's id
---@field filter Tasks.ChecklistFilter
---@field rows table<integer, Tasks.ChecklistEntry>  # buffer line (1-based) -> entry
---@field errors_seen? string                  # the read errors last reported, so a re-render does not repeat them

---One state per list buffer, dropped when the buffer is wiped.
---@type table<integer, Tasks.ChecklistView.State>
local states = {}

-- ── pure parts ───────────────────────────────────────────────────────────────

---A day of the filter line: `YYYY-MM-DD`, `today`, or `<n>d` / `<n>w` (that many days / weeks ago).
---@param value string
---@param today string
---@return string|nil day
local function filter_day(value, today)
  if model.is_date(value) then
    return value
  end
  if value == "today" then
    return today
  end
  local n, unit = value:match("^(%d+)([dw])$")
  if n then
    return model.add_days(today, -tonumber(n) * (unit == "w" and 7 or 1))
  end
  return nil
end

---Read a filter line: `#tag`, `since:<day>`, `until:<day>` (a day is `YYYY-MM-DD`, `today`, `7d`, `2w`),
---`state:open|done|all`; every other word must be in the title, the text or a tag. What cannot be read is named in
---the second answer and left out.
---@param line string
---@param today string  # `YYYY-MM-DD`
---@return Tasks.ChecklistFilter filter
---@return string[] problems
function M.parse_filter(line, today)
  local f, problems, words = { state = "all" }, {}, {}
  for word in (line or ""):gmatch("%S+") do
    local key, value = word:match("^(%a+):(.+)$")
    key = key and key:lower()
    if word:match("^#.") then
      if f.tag then
        -- the filter takes one tag: a second one is named, not silently put in place of the first
        problems[#problems + 1] = word
      else
        f.tag = word:sub(2):lower()
      end
    elseif key == "since" or key == "from" then
      f.since = filter_day(value, today)
      if not f.since then
        problems[#problems + 1] = word
      end
    elseif key == "until" or key == "to" then
      f["until"] = filter_day(value, today)
      if not f["until"] then
        problems[#problems + 1] = word
      end
    elseif key == "state" or key == "is" then
      value = value:lower()
      if vim.tbl_contains(M.STATES, value) then
        f.state = value
      else
        problems[#problems + 1] = word
      end
    else
      words[#words + 1] = word
    end
  end
  if #words > 0 then
    f.q = table.concat(words, " ")
  end
  return f, problems
end

---The filter as the line `parse_filter` reads back ("" for none).
---@param f Tasks.ChecklistFilter
---@return string
function M.format_filter(f)
  local parts = {}
  if f.tag then
    parts[#parts + 1] = "#" .. f.tag
  end
  if f.since then
    parts[#parts + 1] = "since:" .. f.since
  end
  if f["until"] then
    parts[#parts + 1] = "until:" .. f["until"]
  end
  if f.state and f.state ~= "all" then
    parts[#parts + 1] = "state:" .. f.state
  end
  if f.q and f.q ~= "" then
    parts[#parts + 1] = f.q
  end
  return table.concat(parts, " ")
end

---Text read from a file as one line of the buffer.
---@param s string
---@return string
local function one_line(s)
  return (nul_safe(s):gsub("[\r\n]+", " "))
end

---@class Tasks.ChecklistView.Mark
---@field line integer   # 0-based
---@field col integer
---@field end_col integer
---@field group string

---The lines of a list's buffer: its title with the open count, the filter, then one line per entry shown
---(`[ ]`/`[x]`, the day it was made, the title, the tags, the day it was ticked).
---@param list Tasks.Checklist
---@param all Tasks.ChecklistEntry[]   # every entry of the list
---@param shown Tasks.ChecklistEntry[] # the ones the filter lets through, in their order
---@param f Tasks.ChecklistFilter
---@return string[] lines
---@return table<integer, Tasks.ChecklistEntry> rows  # line (1-based) -> entry
---@return Tasks.ChecklistView.Mark[] marks
function M.render(list, all, shown, f)
  local open = 0
  for _, e in ipairs(all) do
    if not e.done then
      open = open + 1
    end
  end
  local title = one_line(list.title)
  local lines = {
    ("%s  ·  %d open of %d"):format(title, open, #all),
    "",
    "",
  }
  local filter = M.format_filter(f)
  if filter == "" then
    lines[2] = "filter: none  ·  g? keys"
  else
    lines[2] = ("filter: %s  ·  %d shown  ·  g? keys"):format(filter, #shown)
  end
  local marks = { { line = 0, col = 0, end_col = #title, group = "TasksChecklistTitle" } }
  local rows = {}
  for _, e in ipairs(shown) do
    local box = e.done and "[x]" or "[ ]"
    local day = e.created:match("^(%d%d%d%d%-%d%d%-%d%d)") or "          "
    local text = one_line(e.title)
    local line = ("%s %s  %s"):format(box, day, text)
    local tag_from = #line
    if #e.tags > 0 then
      line = line .. "  #" .. table.concat(e.tags, " #")
    end
    local tag_to = #line
    if e.done then
      line = line .. "  (done " .. e.done .. ")"
    end
    lines[#lines + 1] = line
    rows[#lines] = e
    local l0 = #lines - 1
    marks[#marks + 1] = { line = l0, col = 4, end_col = 14, group = "TasksChecklistDay" }
    if tag_to > tag_from then
      marks[#marks + 1] =
        { line = l0, col = tag_from + 2, end_col = tag_to, group = "TasksChecklistTag" }
    end
    if e.done then
      marks[#marks + 1] = { line = l0, col = 0, end_col = #line, group = "TasksChecklistDone" }
    end
  end
  if #shown == 0 then
    lines[#lines + 1] = #all == 0 and "(no entries yet: a adds one)"
      or "(nothing matches the filter: F clears it)"
  end
  return lines, rows, marks
end

---One line of the picker of lists.
---@param l { title: string, id: string, open: integer, total: integer }
---@return string
function M.label(l)
  return ("%s  (%d open of %d)  %s"):format(one_line(l.title), l.open, l.total, l.id)
end

---The id of a list named by its id (`_list-support`) or its slug (`support`); a slug is lower case, so `Support`
---names `_list-support` (as `<Tab>` offers it for `Sup`).
---@param name string
---@return string
function M.list_id(name)
  if name:sub(1, #checklist.PREFIX) == checklist.PREFIX then
    return checklist.PREFIX .. name:sub(#checklist.PREFIX + 1):lower()
  end
  return checklist.PREFIX .. name:lower()
end

-- ── the write door ───────────────────────────────────────────────────────────

---Send one operation through the write door; nil and a message on failure.
local run_op = require("tasks_nvim.ui.write_door").run

---@return string|nil root
local function root_or_say()
  local root, err = vault.root()
  if not root then
    notify.error(tostring(err))
  end
  return root
end

-- ── the buffer ───────────────────────────────────────────────────────────────

local function define_highlights()
  local set = vim.api.nvim_set_hl
  set(0, "TasksChecklistTitle", { default = true, link = "Title" })
  set(0, "TasksChecklistDay", { default = true, link = "Number" })
  set(0, "TasksChecklistTag", { default = true, link = "Special" })
  set(0, "TasksChecklistDone", { default = true, link = "Comment" })
end

---The entry under the cursor of list buffer `buf`, or nil (a heading line, an empty list).
---@param buf integer
---@return Tasks.ChecklistEntry|nil
function M.entry_at_cursor(buf)
  local st = states[buf]
  if not st then
    return nil
  end
  return st.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

---Draw list buffer `buf` again from the files. The cursor stays on the entry it was on (or on `focus`, an entry id).
---@param buf integer
---@param focus? string
function M.refresh(buf, focus)
  local st = states[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local root = root_or_say()
  if not root then
    return
  end
  local list, lerr = checklist.list(root, st.list)
  if not list then
    notify.error(tostring(lerr))
    return
  end
  local all, errors = checklist.entries(root, st.list)
  local key = table.concat(errors, "\n")
  if key ~= "" and key ~= st.errors_seen then
    notify.warn(table.concat(errors, "\n"))
  end
  st.errors_seen = key
  local shown = checklist.filter(all, st.filter)
  local lines, rows, marks = M.render(list, all, shown, st.filter)

  -- the window the key was pressed in when it shows the list (a second window on the same list keeps its own cursor),
  -- else the first one that shows it
  local win = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win()
    or vim.fn.bufwinid(buf)
  local old = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil
  focus = focus or (old and st.rows[old[1]] and st.rows[old[1]].id) or nil

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.line, m.col, {
      end_col = m.end_col,
      hl_group = m.group,
    })
  end
  st.rows = rows

  if win ~= -1 then
    local row
    for line, e in pairs(rows) do
      if e.id == focus then
        row = line
      end
    end
    if not row then
      row = math.min(old and old[1] or (M.HEAD + 1), #lines)
      row = math.max(row, math.min(M.HEAD + 1, #lines))
    end
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
end

---@param buf integer
---@param f fun(e: Tasks.ChecklistEntry)
local function with_entry(buf, f)
  local e = M.entry_at_cursor(buf)
  if not e then
    notify.info("no entry under the cursor")
    return
  end
  f(e)
end

---The help lines, from the keys in force.
---@param keys table<string, string|false>
---@return string[]
function M.help_lines(keys)
  local function key(name)
    return keys[name] or "-"
  end
  local rows = {
    { "add", "add an entry (a #word becomes a tag)" },
    { "toggle", "tick it, or open it again" },
    { "open", "open the entry as a file" },
    { "delete", "delete it with its attachments (asks first)" },
    { "promote", "make it a task of an area" },
    { "filter", "filter: #tag since:<day> until:<day> state:open|done words" },
    { "clear", "clear the filter" },
    { "state", "show all, the open or the done ones" },
    { "refresh", "read the files again" },
    { "lists", "pick another list" },
    { "close", "close the list" },
    { "help", "this help" },
  }
  local out = { "Checklist", "" }
  for _, r in ipairs(rows) do
    out[#out + 1] = ("%-6s %s"):format(key(r[1]), r[2])
  end
  vim.list_extend(out, {
    "",
    "A day is YYYY-MM-DD, today, 7d (seven days ago) or 2w.",
  })
  return out
end

---The actions of a list buffer, by the name in `keys.checklist`.
---@param buf integer
---@return table<string, { fn: fun(), desc: string }>
local function actions(buf)
  local st = states[buf]
  return {
    add = {
      desc = "add an entry",
      fn = function()
        vim.ui.input({ prompt = "New entry (#word = tag): " }, function(line)
          if not line or vim.trim(line) == "" then
            return
          end
          local made = run_op({ op = "entry_add", list = st.list, title = line })
          if made then
            M.refresh(buf, made.id)
          end
        end)
      end,
    },
    toggle = {
      desc = "tick or open again",
      fn = function()
        with_entry(buf, function(e)
          -- drawn again also when it was refused: a version changed elsewhere is then the one shown
          run_op({ op = "entry_set", id = e.id, done = not e.done, if_match = e.etag })
          M.refresh(buf, e.id)
        end)
      end,
    },
    open = {
      desc = "open the entry as a file",
      fn = function()
        with_entry(buf, function(e)
          local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(e.path))
          if not ok then
            notify.error(("cannot open %s: %s"):format(e.id, tostring(err)))
          end
        end)
      end,
    },
    delete = {
      desc = "delete the entry",
      fn = function()
        with_entry(buf, function(e)
          local msg = ('Delete "%s"%s?'):format(
            one_line(e.title),
            e.folder and " with its attachments" or ""
          )
          require("tasks_nvim.ui.confirm").yesno(msg, "delete", function(yes)
            if yes then
              run_op({ op = "entry_delete", id = e.id, if_match = e.etag })
              M.refresh(buf)
            end
          end)
        end)
      end,
    },
    promote = {
      desc = "make the entry a task",
      fn = function()
        with_entry(buf, function(e)
          local root = root_or_say()
          if not root then
            return
          end
          local names = {}
          for _, a in ipairs(vault.areas(root)) do
            names[#names + 1] = a.name
          end
          vim.ui.select(names, { prompt = "Make it a task of" }, function(area)
            if not area then
              return
            end
            local made = run_op({ op = "entry_promote", id = e.id, area = area, if_match = e.etag })
            if made then
              notify.info(("%s is now the task %s"):format(e.id, tostring(made.id)))
            end
            M.refresh(buf)
          end)
        end)
      end,
    },
    filter = {
      desc = "filter the entries",
      fn = function()
        vim.ui.input({
          prompt = "Filter (#tag since: until: state: words): ",
          default = M.format_filter(st.filter),
        }, function(line)
          if line == nil then
            return
          end
          local f, problems = M.parse_filter(line, model.today())
          if #problems > 0 then
            notify.warn("not read: " .. table.concat(problems, " "))
          end
          st.filter = f
          M.refresh(buf)
        end)
      end,
    },
    clear = {
      desc = "clear the filter",
      fn = function()
        st.filter = { state = "all" }
        M.refresh(buf)
      end,
    },
    state = {
      desc = "all / open / done",
      fn = function()
        local i = 1
        for n, s in ipairs(M.STATES) do
          if s == (st.filter.state or "all") then
            i = n
          end
        end
        st.filter.state = M.STATES[i % #M.STATES + 1]
        M.refresh(buf)
      end,
    },
    refresh = {
      desc = "read the files again",
      fn = function()
        M.refresh(buf)
      end,
    },
    lists = {
      desc = "pick another list",
      fn = function()
        M.pick()
      end,
    },
    close = {
      desc = "close the list",
      fn = function()
        -- every window on the list shows the alternate buffer (else one empty buffer) first (UI-55): wiping the list
        -- would close them
        local alt = vim.fn.bufnr("#")
        local target = (alt > 0 and alt ~= buf and vim.fn.buflisted(alt) == 1) and alt or nil
        for _, w in ipairs(vim.fn.win_findbuf(buf)) do
          target = target or vim.api.nvim_create_buf(true, false)
          vim.api.nvim_win_set_buf(w, target)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end,
    },
    help = {
      desc = "help",
      fn = function()
        local keys = require("tasks_nvim.config").get().keys.checklist
        require("tasks_nvim.ui.help_float").open(M.help_lines(keys), "tasks_checklist_help")
      end,
    },
  }
end

---Make the buffer of list `id`.
---@param id string
---@return integer buf
local function make_buffer(id)
  define_highlights()
  local bufname = M.SCHEME .. id
  -- a buffer of that name without our state (one deleted halfway, see BufDelete below) would refuse the name
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not states[b] and vim.api.nvim_buf_get_name(b) == bufname then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, bufname)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "tasks_checklist"
  vim.bo[buf].modifiable = false
  states[buf] = { list = id, filter = { state = "all" }, rows = {} }
  local keys = require("tasks_nvim.config").get().keys.checklist or {}
  for name, a in pairs(actions(buf)) do
    local lhs = keys[name]
    if lhs then
      vim.keymap.set("n", lhs, a.fn, { buffer = buf, nowait = true, desc = "tasks: " .. a.desc })
    end
  end
  local group = vim.api.nvim_create_augroup("TasksChecklist" .. buf, { clear = true })
  -- back from an entry opened as a file: its title or tags may have changed
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      states[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  -- `:bdelete` keeps the buffer but drops its keys and autocommands: a list shown in it again would be dead. So a
  -- deleted list buffer is wiped (after the delete has finished), and the next `open` makes a whole one.
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = buf,
    callback = function()
      states[buf] = nil
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end)
    end,
  })
  return buf
end

---The buffer of list `id` when one is open.
---@param id string
---@return integer|nil
function M.buffer_of(id)
  for buf, st in pairs(states) do
    if st.list == id and vim.api.nvim_buf_is_valid(buf) then
      return buf
    end
  end
  return nil
end

---Show list `id` in the current window (its buffer, made when there is none).
---@param id string
---@return integer|nil buf
function M.open(id)
  local root = root_or_say()
  if not root then
    return nil
  end
  local list, err = checklist.list(root, id)
  if not list then
    notify.error(tostring(err))
    return nil
  end
  local buf = M.buffer_of(list.id) or make_buffer(list.id)
  if vim.api.nvim_get_current_buf() ~= buf then
    -- its BufEnter draws it
    vim.api.nvim_win_set_buf(0, buf)
  else
    M.refresh(buf)
  end
  return buf
end

---The lists of the vault with their open and total counts, by title.
---@param root string
---@return { id: string, title: string, open: integer, total: integer }[]
function M.lists(root)
  local out = {}
  for _, l in ipairs(checklist.lists(root)) do
    local all = checklist.entries(root, l.id)
    local open = 0
    for _, e in ipairs(all) do
      if not e.done then
        open = open + 1
      end
    end
    out[#out + 1] = { id = l.id, title = l.title, open = open, total = #all }
  end
  return out
end

---Pick a list and show it.
function M.pick()
  local root = root_or_say()
  if not root then
    return
  end
  local lists = M.lists(root)
  if #lists == 0 then
    notify.info("no checklists yet: :Tasks checklist new <title> makes one")
    return
  end
  vim.ui.select(lists, { prompt = "Checklist", format_item = M.label }, function(choice)
    if choice then
      M.open(choice.id)
    end
  end)
end

-- ── the commands ─────────────────────────────────────────────────────────────

---`:Tasks checklist [<list>]`: the list named, else a picker over the lists.
---@param ctx table
function M.cmd(ctx)
  local list = ctx.args and ctx.args.list or nil
  if list then
    M.open(list)
  else
    M.pick()
  end
end

---`:Tasks checklist new <title...>`: make a list and show it.
---@param ctx table
function M.cmd_new(ctx)
  local title = vim.trim(table.concat(ctx.rest or {}, " "))
  if title == "" then
    notify.error("usage: :Tasks checklist new <title>")
    return
  end
  local made = run_op({ op = "checklist_new", title = title })
  if made then
    M.open(made.id)
  end
end

---`:Tasks checklist add <list> <line...>`: add an entry (a `#word` becomes a tag); a list shown is drawn again.
---@param ctx table
function M.cmd_add(ctx)
  local line = vim.trim(table.concat(ctx.rest or {}, " "))
  if line == "" then
    notify.error("usage: :Tasks checklist add <list> <entry...>")
    return
  end
  local made = run_op({ op = "entry_add", list = ctx.args.list, title = line })
  if not made then
    return
  end
  local buf = M.buffer_of(ctx.args.list)
  if buf then
    M.refresh(buf, made.id)
  end
  notify.info(("%s added"):format(made.id))
end

return M
