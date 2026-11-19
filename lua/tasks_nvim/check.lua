---@module 'tasks_nvim.check'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief The rule checker for the task files (concept section 9).
---@description
--- Reads the open tasks, the finished ones in `Backlog/` and the generated
--- indexes of one area or the whole vault and reports what breaks the rules.
--- Same idea as `md_lint.lua`: a finding is `<path>  <code>  <message>`, and any
--- `error` finding makes the run fail.
---
--- Findings (`code`):
---  - `frontmatter-missing`, `frontmatter-invalid`, `title-missing`,
---    `status-missing`, `field-type`: the file cannot be read as a task
---  - `unknown-status`, `unknown-kind`, `unknown-category`, `unknown-severity`,
---    `bad-prio`, `bad-effort`, `bad-date`, `bad-link` (a `links` entry that is no http(s) address)
---  - `start-after-due`: the `start` date is later than the `due` date
---  - `bad-time`: `remind_at` is not a time of day (`HH:MM`); `remind-at-without-remind` (warning): `remind_at` and no
---    `remind` day; `bad-email`: a `remind_to` entry is no e-mail address (or more than 10); `remind-to-without-remind`
---    (warning)
---  - `ui-tag-without-ux` (warning): an open task with a tag of `M.UI_TAGS` (`ui`, `webui`, ...) and no category
---    `ux` (vault rule R19: the category is the one source for "touches the surface", a tag only says which part)
---  - `outcome-without-reason`, `outcome-on-open-task` (hints, severity `info`): an outcome `seen` / `not-applicable`
---    without `outcome_reason` (open or finished); an outcome on an open task (allowed: a note made in advance)
---  - `ui-word-without-ux` (a hint, `result.hints`, severity `info`): a word of `M.UI_WORDS` in the title of an open task
---    that has neither the category `ux` nor a UI tag. Never an error or a warning, not in the contract document;
---    `opts.ui_words = false` switches it off (`setup({ check = { ui_words_off = { "<vault name>" } } })`)
---  - `effort-without-plan` (warning): an open task (not `parked`) bigger than L and in no plan
---  - `overdue` (warning): an open task (not `parked`) whose `due` date is before today (`opts.today`)
---  - `severity-without-bug-or-security` (warning): `severity` on a task that is
---    neither `kind: bug` nor in the bug/security category
---  - `invalid-waits-for` (error): `waits_for` is not one key (a lower-case word of a-z, 0-9 and -, at most 40
---    characters); `waits-for-without-parked` (warning): `waits_for` on a task that is not `parked`
---  - `slug`: the filename is not a kebab-case slug, or the file is nested
---    anywhere but as `<slug>/<slug>.md` (a folder task)
---  - `slug-conflict`: the same slug exists as a file and as a folder task
---  - `asset-dangling` (warning): a folder task links `assets/<file>` that is not there
---  - `asset-unused` (warning): a folder task has an image in `assets/` that its text never mentions
---  - `index-stale`: `ROADMAP/TASKS.md` is missing, outdated, or left over
---  - `bad-blocked-by`, `blocked-by-self`, `blocked-by-dangling`: the blocker is
---    malformed, the task itself, or exists nowhere; `blocked-by-done` (warning):
---    the blocker is already finished
---  - `blocked-by-cycle` (error): the hard edges form a circle, the members are named
---  - `doing-while-blocked`, `blocked-without-blocker`, `blocker-freed`, `blocked-by-parked` (warnings): the status
---    runs behind what the blockers say (`tasks_nvim.plan` is the one definition of "blocked")
---  - `plan-unknown` (error): `plan:` names no plan file; `bad-plan`, `bad-phase` (errors): a malformed `plan:` /
---    `phase:`; `plan-area`, `plan-phase`, `plan-target-unknown` (warnings): outside the plan's areas, a stage the
---    plan does not list, a target that exists nowhere; a broken plan file is reported with its own codes
---    (`plan-bad-status`, `plan-bad-area`, `plan-bad-target`, `plan-bad-gate`, ...)
---  - `bad-after`, `bad-order`, `after-self`, `after-dangling` (errors): the soft edge `after` and the sort hint `order`
---  - `plan-project-unknown`, `plan-phase-without-project`, `task-plan-and-project`, `project-unknown` (errors): a plan or a
---    task names a project nobody wrote, a plan has a `phase:` but no project, a task has both `plan:` and `project:`;
---    `plan-project-done`, `plan-project-phase`, `project-done`, `project-phase`, `project-area`, `project-gate-soft`,
---    `project-target-unknown` (warnings); a broken project file is reported with its own codes (`project-bad-status`,
---    `project-bad-area`, `project-nested`, ...)
---  - `wikilink-dangling`, `wikilink-ambiguous` (errors): a bare `[[slug]]` in `blocked_by`, `after` or `plan` (or
---    in the `target` of a plan file) names no task or plan, or one in several areas (the candidates are named); a wikilink that resolves is checked as its id
---    with the codes above
---  - `bad-value`, `bad-actor`: `value` is not 1..5, `actor` is not cdx, me or pair
---  - `actor-cdx-waits-on-me` (warning): a task written `actor: cdx` waits on an open task that only the human
---    can do (`model.actor` = `me`): the AI queue holds work that cannot start
---  - `done-in-roadmap`: `status: done` in `ROADMAP/tasks/`
---  - `open-in-backlog`: a task file in `Backlog/` whose status is not `done`
---  - `duplicate-id`: an open task and a finished one share an id
---  - `unreadable`, `index-error`: something could not be read at all
---  - `symlink-task` (error): the task file is a symbolic link or a junction; it is not read (the vault must not point outside itself)
---  - `frontmatter-warning` (warning): a frontmatter line was kept but not understood
---  - `title-comment` (warning): the title has a trailing YAML comment (` #...`)
---  - `area-groups-invalid` (error): `<vault>/area-groups.json` or one of its groups cannot be used;
---    `area-groups-config` (warning): a group of `setup({ area_groups })` cannot be used;
---    `area-group-shadowed`, `area-group-empty`, `area-group-unknown-member`, `area-group-nested` (warnings): a group
---    named like an area (the area wins), one that matches no area, names an area that is none, or names a group
---    (whole-vault runs only, area `""`)
---  - meetings (`<area>/MEETINGS/`, `tasks_nvim.meetings`): a broken meeting file is reported with its own codes
---    (`meeting-bad-status`, `meeting-bad-date`, `meeting-bad-time`, `meeting-end-and-duration`,
---    `meeting-end-before-start`, `meeting-end-without-time`, `meeting-bad-duration`, `meeting-bad-tz`,
---    `meeting-bad-online`, `meeting-bad-recording`, `meeting-bad-task`, `meeting-bad-notify`, `meeting-bad-notify-to`,
---    `meeting-bad-image`, `meeting-bad-icon`, ...); `meeting-id-taken` (error): an open task, plan or project of the
---    area has the same slug; `meeting-task-dangling`, `meeting-image-missing`, `meeting-done-in-future` (warnings):
---    `tasks:` names a task that exists nowhere, `image:` names a file that is not there, a meeting is done before its
---    day; `meeting-done-without-result`, `meeting-overlap` (hints): done without `## Ergebnis` (allowed), two planned
---    meetings of the area at the same time
---  - learning paths (`<area>/ROADMAP/paths/`, `tasks_nvim.paths`): a broken path file with the codes of a plan file
---    as `path-...` (and `path-no-stages`); `path-id-taken` (error); `path-reason-missing`, `path-duplicate-key`,
---    `path-bad-key`, `path-bad-mark`, `path-bad-arrow`, `path-image-outside`, `path-arrow-dangling`,
---    `path-image-missing`, `path-cycle` (warnings): the tree of `## Lernpunkte`
---
--- Not its job: fixing anything (`index.write_area` regenerates an index).

local fsio = require("tasks_nvim.fsio")

---Image extensions (as `mutate.attach` links them with `![]()`).
---@type table<string, boolean>
local IMAGE_EXT =
  { png = true, jpg = true, jpeg = true, gif = true, webp = true, svg = true, bmp = true }
local lernbaum = require("tasks_nvim.lernbaum")
local meetings = require("tasks_nvim.meetings")
local model = require("tasks_nvim.model")
local plan = require("tasks_nvim.plan")
local plans = require("tasks_nvim.plans")
local projects = require("tasks_nvim.projects")
local index = require("tasks_nvim.index")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@class Tasks.CheckOpts
---@field root? string
---@field area? string      # Check one area (blockers are still resolved vault-wide).
---@field today? string     # `YYYY-MM-DD`: the day `overdue` is judged against (default: today).
---@field ui_words? boolean # `false`: no `ui-word-without-ux` hints (default: on).

---@class Tasks.CheckResult
---@field findings Tasks.Finding[]
---@field errors integer
---@field warnings integer
---@field areas integer     # Areas checked.
---@field tasks integer     # Task files read (open and finished).
---@field ok boolean        # No `error` finding.
---@field hints Tasks.Finding[]  # Hints (severity `info`): never fail a run, never counted as a warning.

---@param list Tasks.Finding[]
---@param severity "error"|"warn"
---@param code string
---@param task Tasks.Task|{ area: string, path: string, id?: string }
---@param message string
local function add(list, severity, code, task, message)
  list[#list + 1] = {
    code = code,
    severity = severity,
    area = task.area,
    path = task.path,
    id = task.id,
    message = message,
  }
end

---The files of the saved views that are no view (`<area>/ROADMAP/views/*.md`: a field the engine does not have, no
---frontmatter, a link, a folder that leads out of the vault): a warning each, with the file and the reason. A view is no
---task: a broken one does not fail the run (the document `tasks.views` names it as a problem as well).
---@param findings Tasks.Finding[]
---@param root string
---@param names string[]  # the areas checked
local function view_findings(findings, root, names)
  local checked = {}
  for _, n in ipairs(names) do
    checked[n] = true
  end
  local _, problems = require("tasks_nvim.views").all(root)
  for _, p in ipairs(problems) do
    local area = p.id:match("^([^/]+)/")
    if area and checked[area] then
      add(
        findings,
        "warn",
        "view-invalid",
        { area = area, path = root .. "/" .. p.file },
        "not a view: " .. p.message
      )
    end
  end
end

---The area groups (`<vault>/area-groups.json`): a file or definition that cannot be used is an error, a group that
---misses its point (shadowed by an area, empty, naming an area or group that is none) a warning. Only on a run over the
---whole vault: the file belongs to no area (the findings carry the area `""`).
---@param findings Tasks.Finding[]
---@param root string
local function area_group_findings(findings, root)
  local area_groups = require("tasks_nvim.area_groups")
  local at = { area = "", path = area_groups.path(root) }
  local groups = area_groups.all(root)
  local problems = area_groups.problems(root)
  for _, note in ipairs(problems.file) do
    add(findings, "error", "area-groups-invalid", at, note)
  end
  -- a rejected group of setup(): the file is fine, Neovim's config is not (and the CLI never sees it)
  for _, note in ipairs(problems.config) do
    add(findings, "warn", "area-groups-config", at, note)
  end
  local is_area = {}
  for _, n in ipairs(vault.area_names(root)) do
    is_area[n] = true
  end
  local is_group = {}
  for _, g in ipairs(groups) do
    is_group[g.name] = true
  end
  for _, g in ipairs(groups) do
    if g.shadowed then
      add(
        findings,
        "warn",
        "area-group-shadowed",
        at,
        ("area group '%s' has the name of an area; the area wins"):format(g.name)
      )
    else
      for _, name in ipairs(g.include) do
        if not name:find("[%*%?]") and not is_area[name] then
          if is_group[name] then
            add(
              findings,
              "warn",
              "area-group-nested",
              at,
              ("area group '%s' names the group '%s': groups do not nest"):format(g.name, name)
            )
          else
            add(
              findings,
              "warn",
              "area-group-unknown-member",
              at,
              ("area group '%s' names '%s', which is no area of the vault"):format(g.name, name)
            )
          end
        end
      end
      if #g.members == 0 then
        add(
          findings,
          "warn",
          "area-group-empty",
          at,
          ("area group '%s' matches no area"):format(g.name)
        )
      end
    end
  end
end

---@param a Tasks.Finding
---@param b Tasks.Finding
---@return boolean
local function finding_less(a, b)
  if a.area ~= b.area then
    return a.area < b.area
  end
  if a.path ~= b.path then
    return a.path < b.path
  end
  if a.code ~= b.code then
    return a.code < b.code
  end
  return a.message < b.message
end

---The tags that say "a part of the surface" (rule R19); the category `ux` is what says "touches the surface".
---@type string[]
M.UI_TAGS = { "ui", "ui-kit", "webui", "page", "overlays", "dashboard" }

---Words in a title that hint at the surface. `suffix`: a German noun that also counts at the end of a compound
---(`Hauptfenster`, `Detailansicht`) and with a plural ending; otherwise the word counts alone or with `plural`.
---`window` has no plural on purpose: `Windows` is mostly the system.
---@type { word: string, suffix?: boolean, plural?: string }[]
M.UI_WORDS = {
  { word = "fenster", suffix = true },
  { word = "knopf", suffix = true },
  { word = "button", plural = "buttons" },
  { word = "dialog", suffix = true },
  { word = "ansicht", suffix = true },
  { word = "oberfläche", suffix = true },
  { word = "ui" },
  { word = "view", plural = "views" },
  { word = "window" },
}

---German plural and case endings a `suffix` word may carry.
local SUFFIX_ENDINGS = { "", "e", "en", "n", "s", "es" }

---The first UI word in a title, `nil` when there is none.
---@param title string
---@return string|nil
function M.ui_word(title)
  for token in tostring(title):lower():gmatch("[%w\128-\255]+") do
    for _, w in ipairs(M.UI_WORDS) do
      if token == w.word or (w.plural and token == w.plural) then
        return w.word
      end
      if w.suffix then
        for _, ending in ipairs(SUFFIX_ENDINGS) do
          local whole = w.word .. ending
          if #token >= #whole and token:sub(-#whole) == whole then
            return w.word
          end
        end
      end
    end
  end
  return nil
end

---The outcome hints of one task (open or finished): never a warning, an outcome is a note, not a defect.
---@param hints Tasks.Finding[]
---@param t Tasks.Task
---@param open boolean
local function outcome_findings(hints, t, open)
  if not t.outcome then
    return
  end
  local function hint(code, message)
    hints[#hints + 1] =
      { code = code, severity = "info", area = t.area, path = t.path, id = t.id, message = message }
  end
  local reason = t.outcome_reason and vim.trim(t.outcome_reason) or ""
  if model.OUTCOME_NEEDS_REASON[t.outcome] and reason == "" then
    hint(
      "outcome-without-reason",
      ("outcome %s without outcome_reason: say why it ends without being done"):format(t.outcome)
    )
  end
  if open then
    hint(
      "outcome-on-open-task",
      ("outcome %s on an open task: tasks done writes it when the task is finished"):format(
        t.outcome
      )
    )
  end
end

---Rule R19 on one open task: a UI tag without the category `ux` is a warning, a UI word in the title of a task with
---neither is a hint.
---@param findings Tasks.Finding[]
---@param hints Tasks.Finding[]
---@param t Tasks.Task
---@param words boolean
local function ui_findings(findings, hints, t, words)
  if t.status == "done" or vim.tbl_contains(t.category or {}, "ux") then
    return
  end
  local tags = {}
  for _, tag in ipairs(t.tags or {}) do
    -- a tag written by hand may be `UI`: the rule is about the word, not its case
    if vim.tbl_contains(M.UI_TAGS, tag:lower()) then
      tags[#tags + 1] = tag
    end
  end
  if #tags > 0 then
    add(
      findings,
      "warn",
      "ui-tag-without-ux",
      t,
      ("tag %s without category ux (the category says the task touches the surface)"):format(
        table.concat(tags, ", ")
      )
    )
    return
  end
  local word = words and M.ui_word(t.title or "")
  if word then
    hints[#hints + 1] = {
      code = "ui-word-without-ux",
      severity = "info",
      area = t.area,
      path = t.path,
      id = t.id,
      message = ("the title says '%s': category ux if it touches the surface"):format(word),
    }
  end
end

---Whether the file a link target names exists below `dir`. A target is a URL
---part: `assets/two%20words.png` is the file `two words.png`.
---@param dir string
---@param target string
---@return boolean
local function asset_exists(dir, target)
  -- A link that climbs out of the task's folder (`assets/../../x`, also percent-encoded) names no asset of
  -- this task: it counts as dangling without asking the file system, so a hand-edited body cannot use the
  -- check to probe which files exist elsewhere.
  local decoded = target:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if target:find("..", 1, true) or decoded:find("..", 1, true) then
    return false
  end
  if fsio.is_file(dir .. "/" .. target) then
    return true
  end
  return decoded ~= target and fsio.is_file(dir .. "/" .. decoded)
end

---Relative `assets/...` links of a folder task's body that point at no file.
---@param task Tasks.Task
---@return string[] missing
local function dangling_assets(task)
  local text = fsio.read(task.path)
  if not text then
    return {}
  end
  local dir = fsio.dirname(task.path)
  local missing, seen = {}, {}
  -- `](assets/<name>)`: one linear pass. The gmatch pattern `%]%((assets/[^)%s]+)%)` is quadratic on a body that repeats
  -- `](assets/` without a closing bracket (every start scans to the end of the file and backtracks).
  local pos = 1
  while true do
    local s, e = text:find("](assets/", pos, true)
    if not s then
      break
    end
    local stop = text:find("[)%s]", e + 1)
    if not stop then
      break
    end
    if stop > e + 1 and text:sub(stop, stop) == ")" then
      local target = text:sub(s + 2, stop - 1)
      if not seen[target] then
        seen[target] = true
        if not asset_exists(dir, target) then
          missing[#missing + 1] = target
        end
      end
    end
    pos = math.max(stop, e + 1)
  end
  return missing
end

---Images in a folder task's `assets/`, and in the folders of the kinds below it (`assets/images/`,
---`assets/screenshots/`, `assets/videos/`: where `attach` puts an asset with a kind), that the task's text does not
---mention as `assets/<name>` (a percent-encoded link counts). A name below a kind's folder is `<folder>/<name>`.
---@param task Tasks.Task
---@return string[] names
local function unused_assets(task)
  local text = fsio.read(task.path)
  if not text then
    return {}
  end
  local decoded = text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  local unused = {}
  local subs = { "" }
  for _, sub in pairs(require("tasks_nvim.mutate").ASSET_KIND_DIRS) do
    subs[#subs + 1] = sub .. "/"
  end
  for _, sub in ipairs(subs) do
    local handle = vim.uv.fs_scandir(fsio.dirname(task.path) .. "/assets/" .. sub)
    while handle do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local ext = name:match("%.([%w]+)$")
      if kind ~= "directory" and ext and IMAGE_EXT[ext:lower()] then
        local needle = "assets/" .. sub .. name
        if not text:find(needle, 1, true) and not decoded:find(needle, 1, true) then
          unused[#unused + 1] = sub .. name
        end
      end
    end
  end
  table.sort(unused)
  return unused
end

---What the blocker graph says (`tasks_nvim.plan`), over every open task of the vault, reported for the checked
---areas: a cycle is an error, a status that runs behind the blockers is a warning (a status may trail the facts for a
---moment, a cycle may not).
---@param findings Tasks.Finding[]
---@param open_ids table<string, Tasks.Task>
---@param names string[]  The areas being checked.
---@param scan_opts { root: string }
---@param is_finished fun(id: string): boolean
local function plan_findings(findings, open_ids, names, scan_opts, is_finished)
  local checked = {}
  for _, n in ipairs(names) do
    checked[n] = true
  end
  local all = {}
  for _, t in pairs(open_ids) do
    all[#all + 1] = t
  end
  local blockers =
    plan.index(all, is_finished, plans.all(scan_opts) or {}, projects.all(scan_opts) or {})
  local built = plan.build(all, blockers)

  for _, members in ipairs(built.cycles) do
    -- one finding per cycle, on its first member in a checked area; a task that blocks only itself is
    -- `blocked-by-self` already
    for _, id in ipairs(#members > 1 and members or {}) do
      local t = open_ids[id]
      if t and checked[t.area] then
        add(
          findings,
          "error",
          "blocked-by-cycle",
          t,
          "blocked_by forms a cycle: " .. table.concat(members, " -> ")
        )
        break
      end
    end
  end
  for id, node in pairs(built.nodes) do
    local t = node.task
    if checked[t.area] then
      local waits = {}
      for _, b in ipairs(node.open_blockers) do
        if open_ids[b] then
          waits[#waits + 1] = b
        end
      end
      if t.status == "doing" and #waits > 0 then
        add(
          findings,
          "warn",
          "doing-while-blocked",
          t,
          "status is doing but " .. table.concat(waits, ", ") .. " is still open"
        )
      elseif t.status == "blocked" and #(t.blocked_by or {}) == 0 and #node.open_blockers == 0 then
        -- no `blocked_by` AND no plan gate holding it (a `gate: hard` stage is a blocker of the engine's own)
        add(
          findings,
          "warn",
          "blocked-without-blocker",
          t,
          "status is blocked but blocked_by names nothing"
        )
      elseif t.status == "blocked" and #node.open_blockers == 0 and not node.in_cycle then
        add(
          findings,
          "warn",
          "blocker-freed",
          t,
          "status is blocked but every blocker is finished (set it to open)"
        )
      end
      for _, w in ipairs(built.warnings) do
        if w.code == "blocked-by-parked" and w.id == id then
          add(findings, "warn", "blocked-by-parked", t, w.msg)
        end
      end
    end
  end
end

---The message of a bare `[[slug]]` reference that names no id or several (a task's or a plan file's).
---@param p Tasks.LinkProblem
---@return string
local function link_problem_message(p)
  if #p.candidates == 0 then
    return ("%s %s names no task or plan"):format(p.field, p.raw)
  end
  return ("%s %s names several tasks, write one of them: %s"):format(
    p.field,
    p.raw,
    table.concat(p.candidates, ", ")
  )
end

---Plan files and the tasks that name them (`plan:`, `phase:`), reported for the checked areas. A task that names a
---plan nobody wrote is an error (a typo); a task outside the plan's `areas`, a stage the plan does not list and a
---target that exists nowhere are warnings.
---@param findings Tasks.Finding[]
---@param open_ids table<string, Tasks.Task>
---@param names string[]
---@param scan_opts { root: string }
---@param is_finished fun(id: string): boolean
local function plan_file_findings(findings, open_ids, names, scan_opts, is_finished)
  local checked = {}
  for _, n in ipairs(names) do
    checked[n] = true
  end
  local files = plans.all(scan_opts) or {}
  local by_id = {}
  for _, file in ipairs(files) do
    by_id[file.id] = file
    if checked[file.area] then
      for i, msg in ipairs(file.errors) do
        add(findings, "error", file.error_codes[i] or "frontmatter-invalid", file, msg)
      end
      for _, p in ipairs(file.link_problems or {}) do
        add(findings, "error", p.code, file, link_problem_message(p))
      end
      if file.target and not open_ids[file.target] and not is_finished(file.target) then
        add(
          findings,
          "warn",
          "plan-target-unknown",
          file,
          "target " .. file.target .. " does not exist"
        )
      end
    end
  end
  for _, t in pairs(open_ids) do
    if checked[t.area] and t.plan then
      local file = by_id[t.plan]
      if not file then
        if not is_finished(t.plan) then
          add(
            findings,
            "error",
            "plan-unknown",
            t,
            "plan " .. t.plan .. " is no plan file (ROADMAP/plans/<slug>.md)"
          )
        end
      else
        if #file.areas > 0 and not vim.tbl_contains(file.areas, t.area) then
          add(
            findings,
            "warn",
            "plan-area",
            t,
            ("the plan %s does not list the area %s"):format(t.plan, t.area)
          )
        end
        if
          t.phase
          and #file.phase_order > 0
          and not vim.tbl_contains(file.phase_order, t.phase)
        then
          add(
            findings,
            "warn",
            "plan-phase",
            t,
            ("phase '%s' is not in the phase_order of %s"):format(t.phase, t.plan)
          )
        end
      end
    end
  end
  -- a plan that is being worked on (`doing`) with no open task left does not finish by itself (its last task was
  -- moved away, or finished before the plan named it): say how to finish it. A plan in `planning` may be new, a parked
  -- one waits on purpose.
  local has_open = {}
  for _, t in pairs(open_ids) do
    if t.plan then
      has_open[t.plan] = true
    end
  end
  for _, file in ipairs(files) do
    if checked[file.area] and file.status == "doing" and not has_open[file.id] then
      add(
        findings,
        "warn",
        "plan-no-open-task",
        file,
        ("no open task left in the plan: finish it by hand (plan-close %s), or give it tasks"):format(
          file.id
        )
      )
    end
  end
end

---The findings of the meeting files of the areas checked: a broken file with its own codes, an id another file of the
---area has, a task that exists nowhere, an image that is not there, a meeting done before its day (warnings), and as
---hints a meeting done without a result (allowed: decision F4) and two planned meetings of the area at the same time.
---@param findings Tasks.Finding[]
---@param hints Tasks.Finding[]
---@param open_ids table<string, Tasks.Task>
---@param names string[]
---@param scan_opts table
---@param is_finished fun(id: string): boolean
---@param today string
local function meeting_findings(findings, hints, open_ids, names, scan_opts, is_finished, today)
  local function hint(code, m, message)
    hints[#hints + 1] =
      { code = code, severity = "info", area = m.area, path = m.path, id = m.id, message = message }
  end
  for _, name in ipairs(names) do
    local list, errs = meetings.area(name, scan_opts)
    for _, e in ipairs(type(errs) == "table" and errs or {}) do
      add(
        findings,
        "error",
        "unreadable",
        { area = name, path = vault.meetings_dir(scan_opts.root, name) },
        e
      )
    end
    local timed = {}
    for _, m in ipairs(list or {}) do
      for i, msg in ipairs(m.errors) do
        add(findings, "error", m.error_codes[i] or "frontmatter-invalid", m, msg)
      end
      -- ids are global: a finished task of the same id counts as much as an open one
      if
        open_ids[m.id]
        or is_finished(m.id)
        or (plans.find(m.id, scan_opts))
        or (projects.find(m.id, scan_opts))
      then
        add(
          findings,
          "error",
          "meeting-id-taken",
          m,
          "a task (open or finished), plan or project of the area has the same id: " .. m.id
        )
      end
      for _, id in ipairs(m.tasks) do
        if not open_ids[id] and not is_finished(id) then
          add(findings, "warn", "meeting-task-dangling", m, "tasks: " .. id .. " does not exist")
        end
      end
      if m.image then
        local present = m.folder and fsio.is_file(fsio.dirname(m.path) .. "/" .. m.image)
        if not present then
          add(findings, "warn", "meeting-image-missing", m, "image " .. m.image .. " is not there")
        end
      end
      if m.status == "done" and m.date and m.date > today then
        add(
          findings,
          "warn",
          "meeting-done-in-future",
          m,
          ("done, but the meeting is on %s, after today (%s)"):format(m.date, today)
        )
      end
      if m.status == "done" and not m.has_result then
        hint("meeting-done-without-result", m, "done without a result (## Ergebnis is empty)")
      end
      if m.status == "planned" and m.time and m.start and m.ends then
        timed[#timed + 1] = m
      end
    end
    table.sort(timed, meetings.less)
    for i, a in ipairs(timed) do
      for j = i + 1, #timed do
        local b = timed[j]
        if b.start >= a.ends then
          break
        end
        hint("meeting-overlap", b, ("at the same time as %s (%s)"):format(a.id, a.start))
      end
    end
  end
end

---The ids the arrows of a task's `## Lernpunkte` name (its file read once, only when an arrow leads to it).
---@param task_path string
---@return string[]
local function task_arrows(task_path)
  local text = fsio.read(task_path)
  if not text then
    return {}
  end
  local parsed = require("lib.nvim.markdown.frontmatter").parse(text)
  local body = parsed and parsed.body or text
  return lernbaum.promoted_ids(lernbaum.parse(body))
end

---The findings of the learning paths of the areas checked (`<area>/ROADMAP/paths/`, `tasks_nvim.paths`): a broken
---file with its codes (errors), an id another file of the area has (error), and as warnings the problems of the tree
---(`path-reason-missing`, `path-duplicate-key`, `path-bad-key`, `path-bad-mark`, `path-bad-arrow`,
---`path-image-outside`), an arrow to a task that exists nowhere (`path-arrow-dangling`), an image that is not there
---(`path-image-missing`) and a cycle of promotions over paths and the `## Lernpunkte` of tasks (`path-cycle`). None of
---them refuses a write (R3).
---@param findings Tasks.Finding[]
---@param open_ids table<string, Tasks.Task>
---@param names string[]
---@param scan_opts table
---@param is_finished fun(id: string): boolean
local function path_findings(findings, open_ids, names, scan_opts, is_finished)
  local paths_mod = require("tasks_nvim.paths")
  for _, name in ipairs(names) do
    local list, errs = paths_mod.area(name, scan_opts)
    for _, e in ipairs(type(errs) == "table" and errs or {}) do
      add(
        findings,
        "error",
        "unreadable",
        { area = name, path = vault.paths_dir(scan_opts.root, name) },
        e
      )
    end
    for _, p in ipairs(list or {}) do
      for i, msg in ipairs(p.errors) do
        add(findings, "error", p.error_codes[i] or "frontmatter-invalid", p, msg)
      end
      if
        open_ids[p.id]
        or is_finished(p.id)
        or (plans.find(p.id, scan_opts))
        or (projects.find(p.id, scan_opts))
        or (meetings.find(p.id, scan_opts))
      then
        add(
          findings,
          "error",
          "path-id-taken",
          p,
          "a task (open or finished), plan, project or meeting of the area has the same id: "
            .. p.id
        )
      end
      local tree = p.tree or lernbaum.parse("")
      for _, pr in ipairs(tree.problems) do
        add(findings, "warn", pr.code, p, ("line %d: %s"):format(pr.line, pr.message))
      end
      local dir = fsio.dirname(p.path)
      for _, node in ipairs(tree.nodes) do
        if node.promoted and not open_ids[node.promoted] and not is_finished(node.promoted) then
          add(
            findings,
            "warn",
            "path-arrow-dangling",
            p,
            ("line %d: the arrow names %s, which does not exist"):format(node.line, node.promoted)
          )
        end
        if
          node.image
          and node.image:match("^assets/")
          and not node.image:find("..", 1, true)
          and not (p.folder and fsio.is_file(dir .. "/" .. node.image))
        then
          add(
            findings,
            "warn",
            "path-image-missing",
            p,
            ("line %d: the image %s is not there"):format(node.line, node.image)
          )
        end
      end
      -- a cycle of promotions: the path, the tasks its arrows name, the tasks theirs name, back to one seen on the way
      local state, stack, reported = {}, {}, false
      local function visit(id, arrows)
        state[id] = "on"
        stack[#stack + 1] = id
        for _, next_id in ipairs(arrows) do
          if reported then
            break
          end
          if state[next_id] == "on" then
            local from
            for i, s in ipairs(stack) do
              if s == next_id then
                from = i
                break
              end
            end
            local ring = vim.list_slice(stack, from)
            ring[#ring + 1] = next_id
            add(
              findings,
              "warn",
              "path-cycle",
              p,
              "the promotions run in a circle: " .. table.concat(ring, " -> ")
            )
            reported = true
          elseif state[next_id] == nil then
            local t = open_ids[next_id]
            local done = not t and scan.find_done(next_id, scan_opts) or nil
            local file = (t and t.path) or (done and done.path)
            visit(next_id, file and task_arrows(file) or {})
          end
        end
        table.remove(stack)
        state[id] = "done"
      end
      visit(p.id, lernbaum.promoted_ids(tree))
    end
  end
end

---Project files, the plans that name one (`project:`, `phase:`) and the tasks that name one themselves, reported for
---the checked areas. A project nobody wrote is an error (a typo); a project that is finished already, a stage the
---project does not list, an area the project does not list and a gate that is not enforced across plans are warnings.
---A task has `plan:` or `project:`, never both; a project is not part of another project.
---@param findings Tasks.Finding[]
---@param open_ids table<string, Tasks.Task>
---@param names string[]
---@param scan_opts { root: string }
---@param is_finished fun(id: string): boolean
local function project_findings(findings, open_ids, names, scan_opts, is_finished)
  local checked = {}
  for _, n in ipairs(names) do
    checked[n] = true
  end
  local project_files = projects.all(scan_opts) or {}
  local plan_files = plans.all(scan_opts) or {}
  -- what keeps a project busy: an open plan that names it, an open task of its own
  local busy = {}
  for _, p in ipairs(plan_files) do
    if p.project and p.status ~= "parked" then
      busy[p.project] = true
    end
  end
  for _, t in pairs(open_ids) do
    if t.project then
      busy[t.project] = true
    end
  end
  local by_id = {}
  for _, file in ipairs(project_files) do
    by_id[file.id] = file
    if checked[file.area] then
      for i, msg in ipairs(file.errors) do
        add(findings, "error", file.error_codes[i] or "frontmatter-invalid", file, msg)
      end
      for _, p in ipairs(file.link_problems or {}) do
        add(findings, "error", p.code, file, link_problem_message(p))
      end
      if file.target and not open_ids[file.target] and not is_finished(file.target) then
        add(
          findings,
          "warn",
          "project-target-unknown",
          file,
          "target " .. file.target .. " does not exist"
        )
      end
      -- a project being worked on with no open plan and no own open task does not finish by itself either
      if file.status == "doing" and not busy[file.id] then
        add(
          findings,
          "warn",
          "project-no-open-work",
          file,
          ("no open plan and no open task of its own left: finish it by hand (project-close %s)"):format(
            file.id
          )
        )
      end
      if file.gate == "hard" then
        add(
          findings,
          "warn",
          "project-gate-soft",
          file,
          "gate: hard does not hold across the plans of a project yet: the stages only order them"
        )
      end
    end
  end
  for _, file in ipairs(plan_files) do
    if checked[file.area] then
      if file.phase and not file.project then
        add(
          findings,
          "error",
          "plan-phase-without-project",
          file,
          "phase " .. file.phase .. " names a stage of a project, but the plan has no project:"
        )
      end
      local project = file.project and by_id[file.project]
      if file.project and not project then
        if is_finished(file.project) then
          add(
            findings,
            "warn",
            "plan-project-done",
            file,
            "project " .. file.project .. " is finished, the plan is still open"
          )
        else
          add(
            findings,
            "error",
            "plan-project-unknown",
            file,
            "project " .. file.project .. " is no project file (ROADMAP/projects/<slug>.md)"
          )
        end
      elseif
        project
        and file.phase
        and #project.phase_order > 0
        and not vim.tbl_contains(project.phase_order, file.phase)
      then
        add(
          findings,
          "warn",
          "plan-project-phase",
          file,
          ("phase '%s' is not in the phase_order of %s"):format(file.phase, file.project)
        )
      end
    end
  end
  for _, t in pairs(open_ids) do
    if checked[t.area] and t.project then
      if t.plan then
        add(
          findings,
          "error",
          "task-plan-and-project",
          t,
          "a task has plan: or project:, not both (a task of a plan belongs to its project through it)"
        )
      end
      local project = by_id[t.project]
      if not project then
        if is_finished(t.project) then
          add(
            findings,
            "warn",
            "project-done",
            t,
            "project " .. t.project .. " is finished, the task is still open"
          )
        else
          add(
            findings,
            "error",
            "project-unknown",
            t,
            "project " .. t.project .. " is no project file (ROADMAP/projects/<slug>.md)"
          )
        end
      else
        if #project.areas > 0 and not vim.tbl_contains(project.areas, t.area) then
          add(
            findings,
            "warn",
            "project-area",
            t,
            ("the project %s does not list the area %s"):format(t.project, t.area)
          )
        end
        if
          t.phase
          and #project.phase_order > 0
          and not vim.tbl_contains(project.phase_order, t.phase)
        then
          add(
            findings,
            "warn",
            "project-phase",
            t,
            ("phase '%s' is not in the phase_order of %s"):format(t.phase, t.project)
          )
        end
      end
    end
  end
end

---The marker file `tasks-vault.json`: a vault without one is told once (a warning, the vault works), one with an older
---layout version too. A refused file never gets here: `vault.root()` refuses the vault first.
---@param findings Tasks.Finding[]
---@param root string
local function marker_findings(findings, root)
  local vault_marker = require("tasks_nvim.vault_marker")
  local at = { area = "", path = vault_marker.path(root) }
  local marker = vault_marker.read(root)
  if not marker then
    add(
      findings,
      "warn",
      "vault-marker-missing",
      at,
      "the vault has no tasks-vault.json (layout version, extra areas, defaults); it works without, `:TasksVault create` writes one for a new vault"
    )
  elseif marker.layout_version < vault_marker.LAYOUT_VERSION then
    add(
      findings,
      "warn",
      "vault-marker-outdated",
      at,
      ("tasks-vault.json names layout version %d, this engine writes %d"):format(
        marker.layout_version,
        vault_marker.LAYOUT_VERSION
      )
    )
  end
end

---A `doing` task nobody has claimed for this long (days since `updated`) is told: a forgotten `doing` looks like work
---of a moment ago.
M.DOING_UNCLAIMED_DAYS = 7

---The claims (`tasks_nvim.claims`): one that ran out (`claim-expired`), one for a task that is not open any more
---(`claim-orphan`: the file lives outside the vault's data, so nothing else would notice) and a `doing` task that
---nobody claimed for days (`doing-unclaimed`). All warnings.
---@param findings Tasks.Finding[]
---@param root string
---@param open_ids table<string, Tasks.Task>
---@param names string[]  # the areas checked
---@param today string
local function claim_findings(findings, root, open_ids, names, today)
  local claims = require("tasks_nvim.claims")
  local checked = {}
  for _, n in ipairs(names) do
    checked[n] = true
  end
  local now = claims.now()
  local all = claims.list(root)
  for id, claim in pairs(all) do
    local area = vault.parse_id(id)
    if area and checked[area] then
      local path = ("%s/%s/%s.json"):format(root .. "/" .. claims.DIR, area, id:match("/(.+)$"))
      if not open_ids[id] then
        add(
          findings,
          "warn",
          "claim-orphan",
          { area = area, path = path, id = id },
          ("claim of %s for a task that is not open (a finished or moved task keeps no claim): delete %s"):format(
            claim.by,
            claims.DIR .. "/" .. area
          )
        )
      elseif claim.until_ <= now then
        add(
          findings,
          "warn",
          "claim-expired",
          open_ids[id],
          ("the claim of %s ran out at %s: it counts as free, `claim` takes it over, `release` clears it"):format(
            claim.by,
            claim.until_
          )
        )
      end
    end
  end
  local function days_between(from, to)
    local function at(d)
      local y, m, dd = d:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
      return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
    end
    return math.floor((at(to) - at(from)) / 86400 + 0.5)
  end
  for id, t in pairs(open_ids) do
    if
      checked[t.area]
      and t.status == "doing"
      and not all[id]
      and model.is_date(t.updated)
      and days_between(t.updated, today) >= M.DOING_UNCLAIMED_DAYS
    then
      add(
        findings,
        "warn",
        "doing-unclaimed",
        t,
        ("status is doing since %s and nobody claimed it: `claim` it, or set the status back"):format(
          t.updated
        )
      )
    end
  end
end

---Whether `check` gives the `ui-word-without-ux` hints for the vault at `root`: on, unless `setup({ check = {
---ui_words_off = { ... } } })` names the vault (its configured name or its folder).
---@param root string
---@return boolean
function M.ui_words_on(root)
  local off = (require("tasks_nvim.config").get().check or {}).ui_words_off or {}
  local name, folder = vault.name_of(root), fsio.norm(root)
  for _, v in ipairs(off) do
    if v == name or fsio.norm(vim.fs.normalize(v)) == folder then
      return false
    end
  end
  return true
end

---Run the checks.
---@param opts? Tasks.CheckOpts
---@return Tasks.CheckResult|nil result
---@return string|nil err
function M.run(opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  -- one index of the vault's slugs for every bare `[[slug]]` wikilink of this run, not one per area
  local scan_opts = { root = root, link_resolver = wikilinks.resolver(root) }
  -- every finished-id question of this run: one listing per area's Backlog, not a walk per id
  local is_finished = scan.finished_lookup(scan_opts)

  local names = {}
  if opts.area then
    if not vault.has_area(root, opts.area) then
      return nil, "unknown area: " .. tostring(opts.area)
    end
    names[1] = opts.area
  else
    for _, a in ipairs(vault.areas(root)) do
      names[#names + 1] = a.name
    end
  end

  -- Blockers are resolved against every open task, whichever area is checked. Every area is scanned ONCE here
  -- and the result is reused below (the per-area checks and the index check); scanning it again for each of
  -- those parsed every open task three times (466 tasks: 410 ms instead of ~170 ms).
  ---@type table<string, Tasks.Task>
  local open_ids = {}
  ---@type table<string, { tasks: Tasks.Task[], errors: string[]|string|nil }>
  local by_area = {}
  for _, a in ipairs(vault.areas(root)) do
    local tasks, errs = scan.area(a.name, scan_opts)
    by_area[a.name] = { tasks = tasks or {}, errors = errs }
    for _, t in ipairs(tasks or {}) do
      open_ids[t.id] = t
    end
  end

  local findings = {}
  local task_count = 0
  ---@type Tasks.Finding[]
  local hints = {}

  for _, name in ipairs(names) do
    local scanned = by_area[name] or { tasks = {} }
    local open, walk_errors = scanned.tasks, scanned.errors
    for _, e in ipairs(type(walk_errors) == "table" and walk_errors or {}) do
      add(findings, "error", "unreadable", { area = name, path = vault.tasks_dir(root, name) }, e)
    end
    local finished, backlog_errors = scan.backlog(name, scan_opts)
    finished = finished or {}
    -- A Backlog that could not be read is reported: without it `duplicate-id` stays silent and a blocker that
    -- was finished looks dangling.
    for _, e in ipairs(type(backlog_errors) == "table" and backlog_errors or {}) do
      add(
        findings,
        "error",
        "unreadable",
        { area = name, path = vault.backlog_dir(root, name, "TASKS") },
        e
      )
    end
    local finished_ids = {}
    for _, t in ipairs(finished) do
      finished_ids[t.id] = t
      outcome_findings(hints, t, false)
    end
    for _, t in ipairs(open) do
      outcome_findings(hints, t, true)
    end
    task_count = task_count + #open + #finished

    local seen_slug = {}
    for _, t in ipairs(open) do
      if seen_slug[t.id] then
        add(
          findings,
          "error",
          "slug-conflict",
          t,
          "the same slug exists as a file and as a folder task: " .. seen_slug[t.id]
        )
      end
      seen_slug[t.id] = t.path
      if t.folder then
        for _, target in ipairs(dangling_assets(t)) do
          add(findings, "warn", "asset-dangling", t, "linked asset is missing: " .. target)
        end
        for _, asset in ipairs(unused_assets(t)) do
          add(
            findings,
            "warn",
            "asset-unused",
            t,
            "assets/" .. asset .. " is not linked from the task"
          )
        end
      end
      for i, msg in ipairs(t.errors) do
        add(findings, "error", t.error_codes[i] or "frontmatter-invalid", t, msg)
      end
      for _, w in ipairs(t.warnings) do
        add(findings, "warn", "frontmatter-warning", t, "line kept but not understood: " .. w)
      end
      for _, h in ipairs(t.hints or {}) do
        add(findings, "warn", h.code, t, h.msg)
      end
      for _, p in ipairs(t.link_problems or {}) do
        add(findings, "error", p.code, t, link_problem_message(p))
      end
      if t.status == "done" then
        add(
          findings,
          "error",
          "done-in-roadmap",
          t,
          "status is done but the file is still in ROADMAP/tasks/ (tasks done moves it)"
        )
      end
      if finished_ids[t.id] then
        add(
          findings,
          "error",
          "duplicate-id",
          t,
          "a finished task with this id exists: " .. finished_ids[t.id].path
        )
      end
      for _, ref in ipairs(t.blocked_by) do
        local _, ref_slug = vault.parse_id(ref)
        if ref_slug then
          if ref == t.id then
            add(findings, "error", "blocked-by-self", t, "blocked_by names the task itself")
          elseif open_ids[ref] then
            if t.actor == "cdx" and model.actor(open_ids[ref]) == "me" then
              add(
                findings,
                "warn",
                "actor-cdx-waits-on-me",
                t,
                ("actor is cdx but it waits on %s, which only you can do"):format(ref)
              )
            end
          else
            if is_finished(ref) then
              add(
                findings,
                "warn",
                "blocked-by-done",
                t,
                "blocked_by " .. ref .. " is already finished"
              )
            else
              add(
                findings,
                "error",
                "blocked-by-dangling",
                t,
                "blocked_by " .. ref .. " does not exist"
              )
            end
          end
        end
      end
    end

    for _, t in ipairs(open) do
      -- `after` is a soft edge: it never blocks and a finished target is fine, but a name that exists nowhere is
      -- a typo and the task naming itself is a mistake.
      for _, ref in ipairs(t.after or {}) do
        local _, ref_slug = vault.parse_id(ref)
        if ref_slug then
          if ref == t.id then
            add(findings, "error", "after-self", t, "after names the task itself")
          elseif not open_ids[ref] and not is_finished(ref) then
            add(findings, "error", "after-dangling", t, "after " .. ref .. " does not exist")
          end
        end
      end
    end

    for _, t in ipairs(finished) do
      if t.status ~= "done" then
        add(
          findings,
          "error",
          "open-in-backlog",
          t,
          ("status is '%s' but the file is in Backlog/ (only done belongs there)"):format(
            tostring(t.status)
          )
        )
      end
    end

    local res, ierr = index.write_area(name, { root = root, check = true, scanned = scanned })
    local index_target = { area = name, path = vault.index_path(root, name) }
    if not res then
      add(findings, "error", "index-error", index_target, tostring(ierr))
    elseif res.action == "stale" then
      local why = {
        missing = "ROADMAP/TASKS.md is missing although tasks are open",
        outdated = "ROADMAP/TASKS.md is out of date",
        orphan = "ROADMAP/TASKS.md exists although no task is open",
      }
      add(
        findings,
        "error",
        "index-stale",
        index_target,
        (why[res.reason] or "ROADMAP/TASKS.md is stale") .. " (tasks index regenerates it)"
      )
    end
  end

  plan_findings(findings, open_ids, names, scan_opts, is_finished)
  -- an open task past its due date: a warning, never an error (a parked task waits on purpose)
  local today = opts.today or model.today()
  local words = opts.ui_words
  if words == nil then
    words = M.ui_words_on(root)
  end
  for _, name in ipairs(names) do
    for _, t in ipairs(by_area[name] and by_area[name].tasks or {}) do
      ui_findings(findings, hints, t, words)
      if t.status ~= "parked" and model.is_date(t.due) and t.due < today then
        add(findings, "warn", "overdue", t, ("due %s is before today (%s)"):format(t.due, today))
      end
      local days = model.effort_days(t.effort)
      if t.status ~= "parked" and days and days > model.effort_days("L") and not t.plan then
        add(
          findings,
          "warn",
          "effort-without-plan",
          t,
          ("effort %s is over L: this belongs in a plan (`plan:`)"):format(t.effort)
        )
      end
    end
  end
  plan_file_findings(findings, open_ids, names, scan_opts, is_finished)
  project_findings(findings, open_ids, names, scan_opts, is_finished)
  meeting_findings(findings, hints, open_ids, names, scan_opts, is_finished, today)
  path_findings(findings, open_ids, names, scan_opts, is_finished)
  view_findings(findings, root, names)
  if not opts.area then
    area_group_findings(findings, root)
    marker_findings(findings, root)
  end
  claim_findings(findings, root, open_ids, names, opts.today or model.today())

  table.sort(findings, finding_less)
  table.sort(hints, finding_less)
  local errors, warnings = 0, 0
  for _, f in ipairs(findings) do
    if f.severity == "error" then
      errors = errors + 1
    else
      warnings = warnings + 1
    end
  end
  return {
    findings = findings,
    errors = errors,
    warnings = warnings,
    areas = #names,
    tasks = task_count,
    ok = errors == 0,
    hints = hints,
  },
    nil
end

---`<path relative to the vault>  <code>  <message>`, forward slashes.
---@param finding Tasks.Finding
---@param root string
---@return string
function M.format(finding, root)
  local rel = fsio.norm(finding.path)
  if rel:sub(1, #root + 1) == root .. "/" then
    rel = rel:sub(#root + 2)
  end
  local tag = (finding.severity == "warn" and "warn ")
    or (finding.severity == "info" and "info ")
    or ""
  -- The message and the path carry text from the files (a status, a ref, a file
  -- name): a control character in them must not reach the terminal.
  return fsio.clean(("%s  %s%s  %s"):format(rel, tag, finding.code, finding.message))
end

return M
