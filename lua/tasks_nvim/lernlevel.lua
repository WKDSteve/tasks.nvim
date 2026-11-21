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

---The words `render` writes, by language: the reader takes both (`parse`).
M.WORDS = {
  de = { done = "Pfad fertig", reward = "Belohnung:" },
  en = { done = "Path done", reward = "Reward:" },
}

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
---@field level integer          # The last of the levels reached in a row from level 1; 0: none.
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

---The progress of a tree in percent, rounded down: of the XP when it has any, else of its points (learned one, seen
---one half, dropped out). The second value is what 100 % stands for (XP, or points).
---@param tree Tasks.LernTree
---@return integer percent
---@return integer unit_possible
function M.percent(tree)
  local x = tree.xp
  local p = tree.progress
  if tree.has_xp then
    return x.possible > 0 and math.floor(x.earned * 100 / x.possible) or 0, x.possible
  end
  -- without XP every point weighs one: learned 1, seen one half, dropped out
  local unit_possible = p.total - p.dropped
  return unit_possible > 0 and math.floor((p.learned + p.seen / 2) * 100 / unit_possible) or 0,
    unit_possible
end

---Evaluate the levels against a tree (`lernbaum.parse`, with the task XP given): the level reached, the next one with
---what is missing, and the rewards reached but not granted.
---@param lv Tasks.Levels
---@param tree Tasks.LernTree
---@return Tasks.LevelState
function M.evaluate(lv, tree)
  local x = tree.xp
  local p = tree.progress
  local percent, unit_possible = M.percent(tree)
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
    -- the level is the run of levels reached from the first on: one reached behind a gap (thresholds that do not
    -- rise, `level-order`) does not count
    if reached and not st.next then
      st.level, st.level_name, st.badge = l.number, l.name, l.badge
    elseif not reached and not st.next then
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

-- ── writing the whole section ─────────────────────────────────────────────────

---At most this many threshold lines in a section that `write` makes.
M.MAX_LEVELS = 20
---Longest name of a level, in characters.
M.MAX_NAME = 80
---Longest reward, in characters.
M.MAX_REWARD = 200

---The picture types a badge may be (as the icons of `asset` kind).
local BADGE_EXT = { png = true, jpg = true, jpeg = true, webp = true, svg = true }

---@class Tasks.LevelSpec
---@field threshold integer      # XP (1..999999), or percent (1..100).
---@field unit "xp"|"percent"
---@field name? string
---@field badge? string          # A file below `assets/badges/`.
---@field reward? string
---@field given? boolean         # Only with a reward.

---@class Tasks.LevelsSpec
---@field list Tasks.LevelSpec[]  # The levels in order; their thresholds rise within a unit.
---@field done? { reward?: string, given?: boolean }  # The line for the whole path.

---@param v any
---@return any
local function unnull(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---The number of characters of a UTF-8 text.
---@param s string
---@return integer
local function chars(s)
  return #(s:gsub("[\128-\191]", ""))
end

---A text part of a level line, trimmed, or the reason it cannot be one.
---@param what string
---@param v any
---@param max integer
---@return string|nil text  # nil and no error: absent (nil, `null` or only blanks)
---@return string|nil err
local function text_part(what, v, max)
  v = unnull(v)
  if v == nil then
    return nil
  end
  if type(v) ~= "string" then
    return nil, what .. " must be text"
  end
  if v:find("[%c\127]") then
    return nil, what .. " contains a control character"
  end
  local t = trim(v)
  if t == "" then
    return nil
  end
  if chars(t) > max then
    return nil, ("%s is longer than %d characters"):format(what, max)
  end
  if t:find(" " .. MIDDOT .. " ", 1, true) or t:find(" | ", 1, true) then
    return nil, what .. " must not contain ' " .. MIDDOT .. " ' or ' | ' (they part the line)"
  end
  return t
end

---@param v any
---@param what string
---@return boolean|nil given
---@return string|nil err
local function given_of(v, what)
  v = unnull(v)
  if v == nil then
    return false
  end
  if type(v) ~= "boolean" then
    return nil, what .. ".given must be true or false"
  end
  return v
end

---The lines of a section's levels from a spec (without line endings, the bullet `- ` and the mark included), or why
---the spec cannot be written. What it renders reads back the same (`parse`, `spec_of`).
---@param spec any  # `Tasks.LevelsSpec`
---@param lang? "de"|"en"  # The words of the lines (`M.WORDS`); German without one.
---@return string[]|nil lines
---@return string|nil err
function M.render(spec, lang)
  local words = M.WORDS[lang or "de"] or M.WORDS.de
  if type(spec) ~= "table" or vim.islist(spec) and next(spec) ~= nil then
    return nil, "levels must be an object { list, done? }"
  end
  for key in pairs(spec) do
    if key ~= "list" and key ~= "done" then
      return nil, ("levels: unknown field '%s' (fields: done, list)"):format(tostring(key))
    end
  end
  local list = unnull(spec.list) or {}
  if type(list) ~= "table" or not vim.islist(list) then
    return nil, "levels.list must be a list"
  end
  if #list > M.MAX_LEVELS then
    return nil, ("levels.list has more than %d levels"):format(M.MAX_LEVELS)
  end
  local out, last = {}, {}
  for i, l in ipairs(list) do
    local at = ("levels.list[%d]"):format(i)
    if type(l) ~= "table" or (vim.islist(l) and next(l) ~= nil) then
      return nil, at .. " must be an object"
    end
    for key in pairs(l) do
      if not ({ threshold = 1, unit = 1, name = 1, badge = 1, reward = 1, given = 1 })[key] then
        return nil, ("%s: unknown field '%s'"):format(at, tostring(key))
      end
    end
    local unit = l.unit
    if unit ~= "xp" and unit ~= "percent" then
      return nil, at .. ".unit must be xp or percent"
    end
    local max = unit == "xp" and 999999 or 100
    local th = l.threshold
    if type(th) ~= "number" or th ~= math.floor(th) or th < 1 or th > max then
      return nil, ("%s.threshold must be a whole number from 1 to %d"):format(at, max)
    end
    if last[unit] and th <= last[unit] then
      return nil, ("%s.threshold must rise: %d after %d"):format(at, th, last[unit])
    end
    last[unit] = th
    local name, nerr = text_part(at .. ".name", l.name, M.MAX_NAME)
    if nerr then
      return nil, nerr
    end
    if
      name
      and (
        name:match("^[Bb]adge:?%s")
        or name:match("^!%[")
        or name:match("^[Bb]elohnung:")
        or name:match("^[Rr]eward:")
      )
    then
      return nil, at .. ".name must not read as a badge or a reward"
    end
    local badge = unnull(l.badge)
    if badge ~= nil then
      if
        type(badge) ~= "string"
        or not badge:match("^assets/badges/[^%s%c]+$")
        or badge:find("..", 1, true)
        or badge:find("[%)%(%]%[\\]")
        or not BADGE_EXT[(badge:match("%.(%w+)$") or ""):lower()]
      then
        return nil,
          at .. ".badge must be a png, jpg, jpeg, webp or svg file below assets/badges/ (no blanks)"
      end
    end
    local reward, rerr = text_part(at .. ".reward", l.reward, M.MAX_REWARD)
    if rerr then
      return nil, rerr
    end
    local given, gerr = given_of(l.given, at)
    if gerr then
      return nil, gerr
    end
    -- `%d`: a number that came as 5.0 (Lua 5.4 of the web variant) is written as 5, as the reader reads it
    local parts = { unit == "xp" and ("%d XP"):format(th) or ("%d %%"):format(th) }
    parts[#parts + 1] = name
    parts[#parts + 1] = badge and ("Badge " .. badge) or nil
    parts[#parts + 1] = reward and (words.reward .. " " .. reward) or nil
    out[#out + 1] = ("- [%s] %s"):format(
      (given and reward) and "x" or " ",
      table.concat(parts, " " .. MIDDOT .. " ")
    )
  end
  local done = unnull(spec.done)
  if done ~= nil then
    if type(done) ~= "table" or (vim.islist(done) and next(done) ~= nil) then
      return nil, "levels.done must be an object { reward?, given? }"
    end
    for key in pairs(done) do
      if key ~= "reward" and key ~= "given" then
        return nil, ("levels.done: unknown field '%s'"):format(tostring(key))
      end
    end
    local reward, rerr = text_part("levels.done.reward", done.reward, M.MAX_REWARD)
    if rerr then
      return nil, rerr
    end
    local given, gerr = given_of(done.given, "levels.done")
    if gerr then
      return nil, gerr
    end
    out[#out + 1] = ("- [%s] %s%s"):format(
      (given and reward) and "x" or " ",
      words.done,
      reward and (" " .. MIDDOT .. " " .. words.reward .. " " .. reward) or ""
    )
  end
  return out
end

---The spec of a parsed section, as `render` takes it; nil when the section has lines that a spec cannot hold
---(`level-bad-line`, `level-bad-mark`, `level-order`), so a write of it would lose them.
---@param lv Tasks.Levels
---@return Tasks.LevelsSpec|nil
function M.spec_of(lv)
  if #lv.problems > 0 then
    return nil
  end
  local list = {}
  for _, l in ipairs(lv.levels) do
    list[#list + 1] = {
      threshold = l.threshold,
      unit = l.kind,
      name = l.name,
      badge = l.badge,
      reward = l.reward,
      given = (l.reward and l.given) or nil,
    }
  end
  local spec = { list = list }
  if lv.final then
    spec.done = { reward = lv.final.reward, given = (lv.final.reward and lv.final.given) or nil }
  end
  return spec
end

---Where the `## Level` section of the lines is: its heading, its last line (before the next heading of level 1 or 2)
---and the level lines in it (every `- [?]` line outside a fence).
---@param lines string[]
---@return integer|nil heading
---@return integer|nil last
---@return integer[] items
local function locate(lines)
  local heading, items = nil, {}
  local fence
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
        if heading then
          return heading, i - 1, items
        end
        if #hashes == 2 and is_heading(name) then
          heading = i
        end
      elseif heading and line:match("^%s*[-*+]%s%[.%]") then
        items[#items + 1] = i
      end
    end
  end
  return heading, heading and #lines or nil, items
end

---The language of the words of a body's level lines: `en` when they say `Path done` or `Reward:` and none says
---`Pfad fertig` or `Belohnung:`, `de` the other way round; nil when they say neither (or both).
---@param body string
---@return "de"|"en"|nil
function M.lang_of(body)
  local lines = vim.split(body or "", "\n", { plain = true })
  local heading, _, items = locate(lines)
  if not heading then
    return nil
  end
  local seen = {}
  for _, i in ipairs(items) do
    for lang, w in pairs(M.WORDS) do
      if lines[i]:find(w.done, 1, true) or lines[i]:find(w.reward, 1, true) then
        seen[lang] = true
      end
    end
  end
  if seen.en and not seen.de then
    return "en"
  elseif seen.de and not seen.en then
    return "de"
  end
  return nil
end

---The body with its `## Level` section written from a spec: the level lines of the section are replaced by the
---rendered ones (where the first of them stood), any other text of the section stays; without a section one is added
---at the end. An empty spec (no levels, no `done`) removes the level lines, and the whole section when nothing else is
---in it. The rest of the body stays byte for byte and keeps its line ending.
---The words are the ones the section's level lines use already (`lang_of`), else `opts.lang` (the vault's), else
---German.
---@param body string
---@param spec any  # `Tasks.LevelsSpec`
---@param opts? { lang?: string }
---@return string|nil body
---@return string|nil err
function M.write(body, spec, opts)
  local want = opts and opts.lang
  local lang = M.lang_of(body) or (want and M.WORDS[want] and want) or "de"
  local new, err = M.render(spec, lang)
  if not new then
    return nil, err
  end
  local eol = body:find("\r\n", 1, true) and "\r" or ""
  for i, l in ipairs(new) do
    new[i] = l .. eol
  end
  local lines = vim.split(body, "\n", { plain = true })
  local heading, last, items = locate(lines)
  if not heading then
    if #new == 0 then
      return body
    end
    while #lines > 0 and lines[#lines]:gsub("\r$", "") == "" do
      lines[#lines] = nil
    end
    if #lines > 0 then
      lines[#lines + 1] = eol
    end
    lines[#lines + 1] = "## Level" .. eol
    lines[#lines + 1] = eol
    vim.list_extend(lines, new)
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
  end
  ---@cast last integer
  local drop = {}
  for _, i in ipairs(items) do
    drop[i] = true
  end
  local rest_text = false
  for i = heading + 1, last do
    if not drop[i] and lines[i]:gsub("\r$", "") ~= "" then
      rest_text = true
    end
  end
  local out = {}
  if #new == 0 and not rest_text then
    -- the whole section goes (its own blank lines with it); the lines after it stay
    out = vim.list_slice(lines, 1, heading - 1)
    vim.list_extend(out, vim.list_slice(lines, last + 1))
    if last >= #lines then
      while #out > 0 and out[#out]:gsub("\r$", "") == "" do
        out[#out] = nil
      end
      out[#out + 1] = ""
    end
    return table.concat(out, "\n")
  end
  -- where the new lines go: at the first old level line, else after the heading's blank line
  local at = items[1]
  local insert_blank = false
  if not at then
    if
      heading + 1 <= #lines
      and lines[heading + 1]:gsub("\r$", "") == ""
      and heading + 1 <= last
    then
      at = heading + 2
    else
      at, insert_blank = heading + 1, true
    end
  end
  for i = 1, #lines do
    if i == at then
      if insert_blank then
        out[#out + 1] = eol
      end
      vim.list_extend(out, new)
      if at > last then
        out[#out + 1] = eol
      end
    end
    if not drop[i] then
      out[#out + 1] = lines[i]
    end
  end
  if at > #lines then
    vim.list_extend(out, new)
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

return M
