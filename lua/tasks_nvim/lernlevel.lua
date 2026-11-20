---@module 'tasks_nvim.lernlevel'
---@brief Levels, badges and rewards of a learning path: the section `## Level`, read, evaluated and written back.
---@description
--- Optional, a nice extra: a path without `## Level` works in full (XP and progress yes, no level, no hints). One line
--- per level, the parts apart by ` · ` (also ` | `), in any order after the threshold:
---
---     ## Level
---
---     - [ ] 50 XP · Badge assets/badges/stern.png · Belohnung: großes Eis kaufen
---     - [x] 50 % · Einsteiger · Badge assets/badges/mond.svg · Belohnung: Kino
---     - [ ] Pfad fertig · Belohnung: ein Wochenende am See
---
--- The threshold is `<N> XP` or `<N> %` (of the possible XP; a tree without any XP counts its points instead, learned
--- 1, seen one half, dropped left out), or `Pfad fertig` / `Path done` (every point closed: the one line for the whole
--- path). `Badge <file>` (or `Badge: <file>`, or an image `![…](<file>)`) names a picture below `assets/badges/`;
--- `Belohnung: <text>` (or `Reward:`) what one grants oneself; any other part is the level's name. `[x]` means the
--- reward was granted (`set_reward`). Levels are numbered 1, 2, … in the order of the file; the path line is `done`.
---
--- Pure Lua, no I/O: whether a badge file is there is `check`'s matter (`level-badge-missing`).

local M = {}

---The headings of the section.
M.HEADINGS = { "Level", "Levels", "Stufen" }

---The words of the line for the whole path, lower case.
local DONE_WORDS = { ["pfad fertig"] = true, ["path done"] = true, ["pfad abgeschlossen"] = true }

local MIDDOT = "\194\183" -- U+00B7

---@class Tasks.Level
---@field number? integer        # 1, 2, … in file order; nil for the path line.
---@field ref string             # `"1"`, `"2"`, … or `"done"`: what `set_reward` takes.
---@field line integer           # The line of the body text, 1-based.
---@field kind "xp"|"percent"|"done"
---@field threshold? integer     # XP, or percent.
---@field name? string
---@field badge? string
---@field reward? string
---@field given boolean          # `[x]`: the reward was granted.
---@field mark string
---@field prefix string          # Indent and bullet, as written.
---@field rest string            # The text after `] `, as written (CR included).

---@class Tasks.LevelProblem
---@field code string
---@field line integer
---@field message string

---@class Tasks.Levels
---@field has_section boolean
---@field levels Tasks.Level[]   # The threshold lines, in file order.
---@field final? Tasks.Level     # The line for the whole path.
---@field problems Tasks.LevelProblem[]
---@field lines string[]

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param name string
---@return boolean
local function is_heading(name)
  for _, h in ipairs(M.HEADINGS) do
    if name:lower() == h:lower() then
      return true
    end
  end
  return false
end

---Split a line's text at ` · ` or ` | `.
---@param text string
---@return string[]
local function parts_of(text)
  local out = {}
  local norm = text:gsub(" " .. MIDDOT .. " ", "\1"):gsub(" | ", "\1")
  for part in (norm .. "\1"):gmatch("([^\1]*)\1") do
    local p = trim(part)
    if p ~= "" then
      out[#out + 1] = p
    end
  end
  return out
end

---Read the `## Level` section of a body. Never raises; without the section `has_section` is false.
---@param body string
---@return Tasks.Levels
function M.parse(body)
  local lines = vim.split(body or "", "\n", { plain = true })
  ---@type Tasks.Levels
  local out = { has_section = false, levels = {}, problems = {}, lines = lines }
  local function problem(code, line, msg)
    out.problems[#out.problems + 1] = { code = code, line = line, message = msg }
  end
  local inside, fence = false, nil
  for i, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    if fence then
      if line:match("^%s*" .. fence) then
        fence = nil
      end
    elseif line:match("^%s*```") or line:match("^%s*~~~") then
      fence = line:match("^%s*(```)") or "~~~"
    else
      local hashes, name = line:match("^(#+)%s+(.-)%s*$")
      if hashes and #hashes <= 2 then
        inside = #hashes == 2 and is_heading(name)
        out.has_section = out.has_section or inside
      elseif inside then
        local ws, bullet, mark, text = line:match("^(%s*)([-*+])%s%[(.)%]%s?(.*)$")
        if ws then
          ---@type Tasks.Level
          local lv = {
            ref = "",
            line = i,
            kind = "xp",
            given = mark == "x" or mark == "X",
            mark = mark,
            prefix = ws .. bullet .. " ",
            rest = raw:match("^%s*[-*+]%s%[.%]%s?(.*)$") or "",
          }
          if mark ~= " " and not lv.given then
            problem("level-bad-mark", i, ("unknown mark [%s] (expected [ ] or [x])"):format(mark))
          end
          local parts = parts_of(text)
          local head = parts[1] or ""
          local n, unit = head:match("^(%d+)%s*([Xx][Pp])$")
          if not n then
            n, unit = head:match("^(%d+)%s*(%%)$")
          end
          if n and #n <= 6 then
            lv.kind = unit == "%" and "percent" or "xp"
            lv.threshold = tonumber(n)
          elseif DONE_WORDS[head:lower()] then
            lv.kind = "done"
          else
            lv.kind = nil
          end
          for k = 2, #parts do
            local p = parts[k]
            local badge = p:match("^[Bb]adge:?%s+(%S+)$")
              or p:match("^!%[[^%]]*%]%(([^%)%s]+)[^%)]*%)$")
            local reward = p:match("^[Bb]elohnung:%s*(.-)$") or p:match("^[Rr]eward:%s*(.-)$")
            if badge then
              lv.badge = badge
            elseif reward then
              lv.reward = reward ~= "" and reward or nil
            elseif not lv.name then
              lv.name = p
            end
          end
          if not lv.kind then
            problem(
              "level-bad-line",
              i,
              ("a level starts with its threshold (50 XP, 50 %%) or 'Pfad fertig', got '%s'"):format(
                head
              )
            )
          else
            if
              lv.badge and (lv.badge:find("..", 1, true) or not lv.badge:match("^assets/badges/"))
            then
              problem(
                "level-badge-outside",
                i,
                "a badge must be a file below assets/badges/: " .. lv.badge
              )
            end
            if lv.kind == "done" then
              if out.final then
                problem(
                  "level-bad-line",
                  i,
                  ("a second line for the whole path (the first is on line %d)"):format(
                    out.final.line
                  )
                )
              else
                lv.ref = "done"
                out.final = lv
              end
            else
              lv.number = #out.levels + 1
              lv.ref = tostring(lv.number)
              out.levels[#out.levels + 1] = lv
            end
          end
        end
      end
    end
  end
  -- thresholds ascending within one unit (XP against percent is compared in `evaluate`, when the maximum is known)
  local last = {}
  for _, lv in ipairs(out.levels) do
    local prev = last[lv.kind]
    if prev and lv.threshold <= prev.threshold then
      problem(
        "level-order",
        lv.line,
        ("the thresholds must rise: %d %s after %d on line %d"):format(
          lv.threshold,
          lv.kind == "xp" and "XP" or "%",
          prev.threshold,
          prev.line
        )
      )
    end
    last[lv.kind] = lv
  end
  return out
end

---@class Tasks.LevelState
---@field has_levels boolean
---@field percent integer        # The progress in percent (of the XP, or of the points without XP), rounded down.
---@field level integer          # The highest level reached; 0: none.
---@field level_name? string
---@field badge? string          # The badge of that level.
---@field next? { number: integer, name?: string, missing_xp?: integer, missing_percent?: integer }
---@field finished boolean       # Every point closed (the path line is reached).
---@field reached table<string, boolean>  # ref -> reached.
---@field open_rewards { ref: string, reward: string }[]  # Reached, with a reward, not granted yet.
---@field problems Tasks.LevelProblem[]  # `level-order` across units.

---The XP a level stands for, when it can be told (XP, or percent of a known maximum).
---@param lv Tasks.Level
---@param possible integer
---@return number|nil
local function as_xp(lv, possible)
  if lv.kind == "xp" then
    return lv.threshold
  elseif lv.kind == "percent" and possible > 0 then
    return lv.threshold * possible / 100
  end
  return nil
end

---Evaluate the levels against a tree (`lernbaum.parse`, with the task XP given): the level reached, the next one with
---what is missing, and the rewards reached but not granted.
---@param lv Tasks.Levels
---@param tree Tasks.LernTree
---@return Tasks.LevelState
function M.evaluate(lv, tree)
  local x = tree.xp
  local p = tree.progress
  local percent
  local unit_possible
  if tree.has_xp then
    unit_possible = x.possible
    percent = x.possible > 0 and math.floor(x.earned * 100 / x.possible) or 0
  else
    -- without XP every point weighs one: learned 1, seen one half, dropped out
    unit_possible = p.total - p.dropped
    percent = unit_possible > 0 and math.floor((p.learned + p.seen / 2) * 100 / unit_possible) or 0
  end
  local finished = p.total > 0 and p.open == 0
  ---@type Tasks.LevelState
  local st = {
    has_levels = #lv.levels > 0 or lv.final ~= nil,
    percent = percent,
    level = 0,
    finished = finished,
    reached = {},
    open_rewards = {},
    problems = {},
  }
  for _, l in ipairs(lv.levels) do
    local reached
    if l.kind == "xp" then
      reached = tree.has_xp and x.earned >= l.threshold
    else
      reached = unit_possible > 0 and percent >= l.threshold
    end
    st.reached[l.ref] = reached
    if reached then
      st.level, st.level_name, st.badge = l.number, l.name, l.badge
    elseif not st.next then
      local nx = { number = l.number, name = l.name }
      if l.kind == "xp" then
        nx.missing_xp = l.threshold - x.earned
      elseif tree.has_xp then
        nx.missing_xp = math.max(0, math.ceil(l.threshold * x.possible / 100) - x.earned)
      else
        nx.missing_percent = l.threshold - percent
      end
      st.next = nx
    end
  end
  if lv.final then
    st.reached.done = finished
  end
  for _, l in ipairs(vim.list_extend(vim.list_slice(lv.levels, 1), { lv.final })) do
    if st.reached[l.ref] and l.reward and not l.given then
      st.open_rewards[#st.open_rewards + 1] = { ref = l.ref, reward = l.reward }
    end
  end
  -- across units: XP and percent compared once the maximum is known
  local prev
  for _, l in ipairs(lv.levels) do
    local v = as_xp(l, x.possible)
    if v and prev and prev.v and v <= prev.v and prev.l.kind ~= l.kind then
      st.problems[#st.problems + 1] = {
        code = "level-order",
        line = l.line,
        message = ("the thresholds must rise: line %d is no higher than line %d (%d XP possible)"):format(
          l.line,
          prev.l.line,
          x.possible
        ),
      }
    end
    if v then
      prev = { v = v, l = l }
    end
  end
  return st
end

---Mark a reward granted (`given = true`, `[x]`) or not (`[ ]`): only the mark of its line changes, every other byte
---stays. `ref` is the level number (`1`, `"2"`) or `"done"` for the whole path. A level without a reward is refused.
---@param lv Tasks.Levels
---@param ref string|integer
---@param given boolean
---@return string|nil body
---@return string|nil err
function M.set_reward(lv, ref, given)
  ref = tostring(ref)
  local target
  for _, l in ipairs(lv.levels) do
    if l.ref == ref then
      target = l
    end
  end
  if ref == "done" then
    target = lv.final
  end
  if not target then
    return nil, ("no such level: %s (a number from 1 to %d, or done)"):format(ref, #lv.levels)
  end
  if not target.reward then
    return nil, ("level %s has no reward (Belohnung: …)"):format(ref)
  end
  local out = vim.list_slice(lv.lines, 1)
  target.mark = given and "x" or " "
  target.given = given == true
  local sep = out[target.line]:match("^%s*[-*+]%s%[.%](%s?)") or " "
  out[target.line] = target.prefix .. "[" .. target.mark .. "]" .. sep .. target.rest
  lv.lines = out
  return table.concat(out, "\n"), nil
end

return M
