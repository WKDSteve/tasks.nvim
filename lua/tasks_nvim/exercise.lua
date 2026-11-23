---The exercise block under a learning point: the note (`> ` lines) of a point that is an exercise carries four labelled
---parts, so the point itself stays a title and the task behind it can be done and proven.
---
---    - [ ] Üben: Verzeichnis anzeigen {xp=10} {#u1}
---      > **Aufgabe:** What exactly to do: place, commands, inputs.
---      > **Fertig, wenn:** How you can tell it worked.
---      > **Nachweis:** What to enter when ticking it off.
---      > **Ergebnis:** The learner's proof, written when ticking it off.
---
---The format is `ALL/Lernpunkt-Aufgabenblock-Format-2026-11-23.md` of the tasks-vault. A part runs over several `> `
---lines until the next label. A point with a `Nachweis` needs a non-empty `Ergebnis` before it may be `learned`
---(`LP-04`: done means proof, not read); points without a block behave as before.
---
---Pure functions on text; the tree and the file are `tasks_nvim.lernbaum` and `tasks_nvim.paths`.
---@class Tasks.Exercise
local M = {}

---@alias Tasks.ExerciseKey "aufgabe"|"fertig"|"nachweis"|"ergebnis"

---The label of each part, as written between `**` and `:**`.
---@type table<Tasks.ExerciseKey, string>
M.LABELS = {
  aufgabe = "Aufgabe",
  fertig = "Fertig, wenn",
  nachweis = "Nachweis",
  ergebnis = "Ergebnis",
}

---@type table<string, Tasks.ExerciseKey>
local KEY_OF = {}
for key, label in pairs(M.LABELS) do
  KEY_OF[label:lower()] = key
end

---The prefixes of a label that make a point an exercise (the title of the point, before the colon or the dash).
local PREFIXES = { "Üben:", "Ueben:", "Übung:", "Aufgabe:", "Mini-Projekt", "Projekt:" }

---@param text string
---@return string
local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---A label line of the note: `**Label:** rest`. The label may hold a comma and spaces (`Fertig, wenn`).
---@param line string
---@return string|nil label  # Lower-cased.
---@return string|nil rest
local function label_line(line)
  local label, rest = line:match("^%s*%*%*([^*]-):%*%*%s*(.-)%s*$")
  if label then
    return trim(label):lower(), rest
  end
  return nil, nil
end

---Whether the title of a point makes it an exercise (`Üben: …`, `Mini-Projekt …`, `Aufgabe: …`).
---@param label? string
---@return boolean
function M.is_exercise(label)
  if type(label) ~= "string" then
    return false
  end
  local text = trim(label)
  for _, prefix in ipairs(PREFIXES) do
    if text:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

---The parts of a note: each present label with its text (the lines of a part joined by one space, trimmed; an
---empty part is `""`). Text before the first label and parts with an unknown label are not parts of the block.
---@param note? string  # The `> ` lines of the point joined by newlines (`Tasks.LernNode.note`).
---@return table<Tasks.ExerciseKey, string> parts
function M.parse(note)
  local parts = {}
  if type(note) ~= "string" or note == "" then
    return parts
  end
  local current
  for line in (note .. "\n"):gmatch("(.-)\r?\n") do
    local label, rest = label_line(line)
    if label then
      current = KEY_OF[label]
      if current then
        parts[current] = parts[current] and (parts[current] .. " " .. rest) or rest
      end
    elseif current then
      local text = trim(line)
      if text ~= "" then
        parts[current] = trim(parts[current] .. " " .. text)
      end
    end
  end
  for key, text in pairs(parts) do
    parts[key] = trim(text)
  end
  return parts
end

---Whether the note carries an exercise block: at least the part `Aufgabe`.
---@param note? string
---@return boolean
function M.has_block(note)
  return M.parse(note).aufgabe ~= nil
end

---An exercise point whose note has no task text: `Aufgabe` missing or empty (`path-exercise-vague`).
---@param label? string
---@param note? string
---@return boolean
function M.is_vague(label, note)
  if not M.is_exercise(label) then
    return false
  end
  local aufgabe = M.parse(note).aufgabe
  return aufgabe == nil or aufgabe == ""
end

---Whether ticking the point off must wait for a result: its block names a `Nachweis` and the `Ergebnis` is empty
---or missing.
---@param note? string
---@return boolean
function M.needs_result(note)
  local parts = M.parse(note)
  local nachweis = parts.nachweis
  return nachweis ~= nil and nachweis ~= "" and (parts.ergebnis == nil or parts.ergebnis == "")
end

---The note with the `Ergebnis` part set to `text` (one line or several): the part is replaced where it stands, or
---added after the last line when the block has none. Every other line is kept. An empty text leaves the label alone.
---@param note string
---@param text? string
---@return string|nil note
---@return string|nil err
function M.with_result(note, text)
  if not M.has_block(note) then
    return nil, "the point has no exercise block (a note with **Aufgabe:**)"
  end
  text = trim(text or "")
  if text:find("[%z\1-\8\11\12\14-\31\127]") then
    return nil, "the result must be text without control characters"
  end
  local lines = {}
  for line in (note .. "\n"):gmatch("(.-)\r?\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and trim(lines[#lines]) == "" do
    lines[#lines] = nil
  end
  local first, last
  for i, line in ipairs(lines) do
    local label = label_line(line)
    if label == "ergebnis" and not first then
      first, last = i, i
    elseif first and i == last + 1 and not label then
      last = i
    elseif first and label then
      break
    end
  end
  local new_lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    new_lines[#new_lines + 1] = line
  end
  new_lines[1] = "**"
    .. M.LABELS.ergebnis
    .. ":**"
    .. (new_lines[1] ~= "" and (" " .. new_lines[1]) or "")
  if first then
    for _ = first, last do
      table.remove(lines, first)
    end
    for offset, line in ipairs(new_lines) do
      table.insert(lines, first + offset - 1, line)
    end
  else
    for _, line in ipairs(new_lines) do
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\n")
end

return M
