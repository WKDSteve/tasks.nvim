---@module 'tasks_nvim.path_schedule'
---@brief The schedule of a learning path made from its tree: the table of `## Zeitplan` generated, not kept twice.
---@description
--- A path with a fixed rhythm (weeks, sessions) has its sessions as points of the tree, one level below the stages
--- (`- [ ] Woche 1: Prozesse {h=8-10} {#w1}`). A point that carries planned hours (`{h=N}` or `{h=N-M}`, `lernbaum`) is
--- a row of the schedule, in the order of the file; a root with hours is a row as well. The table says:
---
---     | Sitzung | Dauer | Ergebnis | Stand |
---
--- `Dauer` the planned hours (`8–10 h`) and, when the point carries `{done_h=N}`, the hours it took (LP-10);
--- `Ergebnis` the text of its first child that starts with `Nachweis:`, `Aufgabe:` or `Ergebnis:` (`–` without one);
--- `Stand` `offen`, `teilweise n/m` (its leaves closed of all) or `erledigt`. A last row sums the hours.
---
--- The table stands between `<!-- GENERATED:schedule start -->` and `<!-- GENERATED:schedule end -->` in the section
--- `## Zeitplan` (`## Schedule`); `place` puts it there: between the markers when they are there, else in place of the
--- first table of the section (a hand-kept one), else right below the heading. A path without `{h=…}` has no schedule;
--- nothing asks for one.
---
--- Pure Lua, no I/O: `paths.write_schedule` reads and writes the file.

local M = {}

M.START = "<!-- GENERATED:schedule start -->"
M.END = "<!-- GENERATED:schedule end -->"

---The headings of the section, German and English.
M.HEADINGS = { "Zeitplan", "Schedule" }

---The words a child's label starts with when it is the result of its session.
local RESULT_WORDS = { "Nachweis", "Aufgabe", "Ergebnis", "Result" }

local EN_DASH = "\226\128\147"

---@class Tasks.ScheduleRow
---@field index integer   # The point's `index` in the tree.
---@field node Tasks.LernNode
---@field line integer
---@field key? string
---@field label string
---@field h_min number
---@field h_max number
---@field done_h? number
---@field result? string
---@field state "open"|"partial"|"done"
---@field closed integer   # Leaves closed (learned, seen, dropped).
---@field total integer

---A number of hours as written: `8`, `1.5` (a comma reads as a point).
---@param n number
---@return string
local function hours(n)
  local s = ("%g"):format(n)
  return s
end

---@param node Tasks.LernNode
---@return string|nil
local function result_of(node)
  for _, c in ipairs(node.children) do
    local label = vim.trim(c.label)
    for _, w in ipairs(RESULT_WORDS) do
      local rest = label:match("^" .. w .. "%s*:%s*(.-)$")
      if rest then
        return rest ~= "" and rest or nil
      end
    end
  end
  return nil
end

---The rows of the schedule: the points with planned hours, in the order of the file.
---@param tree Tasks.LernTree
---@return Tasks.ScheduleRow[]
function M.rows(tree)
  local out = {}
  for _, node in ipairs(tree.nodes) do
    if node.h_min and node.depth <= 1 then
      local p = node.progress
      local closed = p.learned + p.seen + p.dropped
      local state = "open"
      if node.closed then
        state = "done"
      elseif closed > 0 then
        state = "partial"
      end
      out[#out + 1] = {
        index = node.index,
        node = node,
        line = node.line,
        key = node.key,
        label = node.label,
        h_min = node.h_min,
        h_max = node.h_max,
        done_h = node.done_h,
        result = result_of(node),
        state = state,
        closed = closed,
        total = p.total,
      }
    end
  end
  return out
end

---A cell of a Markdown table: one line, `|` escaped.
---@param s string
---@return string
local function cell(s)
  s = s:gsub("[\r\n]+", " ")
  return (s:gsub("|", "\\|"))
end

---@param min number
---@param max number
---@return string
local function span(min, max)
  if min == max then
    return hours(min) .. " h"
  end
  return hours(min) .. EN_DASH .. hours(max) .. " h"
end

---The table of the rows (Markdown lines, without the markers); nil when there are none.
---@param rows Tasks.ScheduleRow[]
---@return string[]|nil
function M.render(rows)
  if #rows == 0 then
    return nil
  end
  local lines = { "| Sitzung | Dauer | Ergebnis | Stand |", "| --- | --- | --- | --- |" }
  local min, max, took, done = 0, 0, 0, 0
  local any_took = false
  for _, r in ipairs(rows) do
    local dauer = span(r.h_min, r.h_max)
    if r.done_h then
      dauer = dauer .. " (gebraucht " .. hours(r.done_h) .. " h)"
      took, any_took = took + r.done_h, true
    end
    local stand = r.state == "done" and "erledigt"
      or r.state == "partial" and ("teilweise %d/%d"):format(r.closed, r.total)
      or "offen"
    if r.state == "done" then
      done = done + 1
    end
    min, max = min + r.h_min, max + r.h_max
    lines[#lines + 1] = ("| %s | %s | %s | %s |"):format(
      cell(r.label),
      dauer,
      cell(r.result or EN_DASH),
      stand
    )
  end
  local sum = span(min, max)
  if any_took then
    sum = sum .. " (gebraucht " .. hours(took) .. " h)"
  end
  lines[#lines + 1] = ("| Summe | %s | | %d/%d erledigt |"):format(sum, done, #rows)
  return lines
end

---@param line string
---@return string|nil name, integer|nil level
local function heading(line)
  local hashes, name = line:gsub("\r$", ""):match("^(#+)%s+(.-)%s*$")
  return name, hashes and #hashes or nil
end

---Put the table into a body: between the markers, else in place of the first table of `## Zeitplan`, else below its
---heading. The line ends of the body are kept (CRLF when its first line ends so).
---@param body string
---@param lines string[]
---@return string|nil body
---@return string|nil err
function M.place(body, lines)
  local all = vim.split(body, "\n", { plain = true })
  local cr = (all[1] or ""):sub(-1) == "\r" and "\r" or ""
  local block = { M.START .. cr }
  for _, l in ipairs(lines) do
    block[#block + 1] = l .. cr
  end
  block[#block + 1] = M.END .. cr
  local function splice(first, last)
    local out = {}
    for i = 1, first - 1 do
      out[#out + 1] = all[i]
    end
    vim.list_extend(out, block)
    for i = last + 1, #all do
      out[#out + 1] = all[i]
    end
    return table.concat(out, "\n")
  end
  -- the markers, when the table was made before
  local s, e
  for i, l in ipairs(all) do
    local t = vim.trim(l)
    if t == M.START and not s then
      s = i
    elseif t == M.END and s and not e then
      e = i
    end
  end
  if s and e then
    return splice(s, e)
  elseif s or e then
    return nil, "the schedule's markers are not a pair: " .. M.START .. " … " .. M.END
  end
  -- the section
  local at
  for i, l in ipairs(all) do
    local name, level = heading(l)
    if level == 2 then
      for _, h in ipairs(M.HEADINGS) do
        if name:lower() == h:lower() then
          at = i
        end
      end
      if at then
        break
      end
    end
  end
  if not at then
    return nil, "the path has no section ## Zeitplan"
  end
  local first, last
  for i = at + 1, #all do
    local _, level = heading(all[i])
    if level and level <= 2 then
      break
    end
    if all[i]:match("^%s*|") then
      first = first or i
      last = i
    elseif first then
      break
    end
  end
  if first then
    return splice(first, last)
  end
  -- below the heading, a blank line before and after
  local out = {}
  for i = 1, at do
    out[#out + 1] = all[i]
  end
  out[#out + 1] = cr
  vim.list_extend(out, block)
  local nxt = all[at + 1]
  if nxt and nxt:match("%S") then
    out[#out + 1] = cr
  end
  for i = at + 1, #all do
    out[#out + 1] = all[i]
  end
  return table.concat(out, "\n")
end

return M
