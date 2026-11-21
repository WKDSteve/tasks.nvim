---@module 'tasks_nvim.plans'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Plan files: one Markdown file per undertaking under `<area>/ROADMAP/plans/`, that tasks point at with `plan:`.
---@description
--- A plan file holds what a human has to justify -- the goal, the boundaries, the definition of done, the names of the
--- stages -- and NO task list: the tasks carry the reference (`plan: <area>/<slug>`, `phase: <word>`), the plan is
--- drawn from them. Two tasks on two machines never collide on a list in the plan file.
---
--- Frontmatter (flat): `title`, `status` (`planning`, `doing`, `parked`, `done`), `areas` (the areas whose tasks may
--- belong), `target` (a task: "done when this is"), `phase_order` (stage names, in order), `gate` (`hard`: a stage
--- may not begin before the earlier ones are finished; absent: the order is only a soft hint), `created`, `updated`,
--- and, for a plan that belongs to a project (`tasks_nvim.projects`), `project` (the project's id or a wikilink) and
--- `phase` (a stage of that project's `phase_order`).
---
--- A project file has the same shape (`parse` with `kind = "project"`); it has no `project:` or `phase:` itself: the
--- levels are fixed (project, plan, task), a project in a project is a mistake (`project-nested`).
---
--- A plan is finished like a task (rule R6, moved to `Backlog/FEATURES/` with a row in the Backlog README) when its
--- last member task is done: `close` does it. Plans are optional: without a plan file and without `plan:` the world
--- is as before.
---
--- Not its job: drawing the plan from the members (`plan`), the engine's done chain (`done_flow` calls `close`).

local checkpoint = require("lib.nvim.checkpoint")
local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local model = require("tasks_nvim.model")
local scan = require("tasks_nvim.scan")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@type string[]
M.STATUSES = { "planning", "doing", "parked", "done" }

---@class Tasks.PlanFile
---@field id string                   # `<area>/<slug>`.
---@field area string
---@field slug string
---@field path string
---@field location "roadmap"|"backlog"
---@field title string
---@field status? string
---@field areas string[]
---@field target? string             # The task id; a wikilink in the file (`[[<slug>]]`, `[[<area>/<slug>]]`, a vault path) is read as its id.
---@field target_raw? string         # `target` as the file writes it (an id or a wikilink).
---@field link_problems? Tasks.LinkProblem[]  # A bare `[[slug]]` target that names no id or several (`check`: `wikilink-dangling`, `wikilink-ambiguous`); `target` is nil then.
---@field kind "plan"|"project"|"path"  # Which kind of file this is (a project file and a learning path are read by the same parser).
---@field tree? Tasks.LernTree        # A learning path only: the tree of `## Lernpunkte` (`tasks_nvim.lernbaum`).
---@field levels? Tasks.Levels        # A learning path only: the section `## Level` (`tasks_nvim.lernlevel`).
---@field body_offset? integer        # The lines before the body (the frontmatter block): a line of `tree` or `levels` plus this is the line of the file.
---@field level_state? Tasks.LevelState  # A learning path only: the levels against the tree (`paths` sets it).
---@field project? string             # A plan only: the project it belongs to (an id; a wikilink in the file is read as its id).
---@field project_raw? string         # `project` as the file writes it (an id or a wikilink).
---@field phase? string               # A plan only: its stage in the project's `phase_order`.
---@field phase_order string[]
---@field links string[]              # Web addresses (`links:`, http/https); an entry that is none is `bad-link`.
---@field tags string[]               # `tags:`; a path's `on-workstation` / `not-on-workstation` goes to the tasks `promote` makes of it.
---@field folder boolean              # The folder form `<slug>/<slug>.md`: the other files in that folder are its assets.
---@field gate? string                # `hard` or nil.
---@field created? string
---@field updated? string
---@field summary string
---@field icon? Tasks.Icon             # `icon:` (`model.icon_of`).
---@field cover? string               # `cover:`, a picture below `assets/` of the folder.
---@field errors string[]
---@field error_codes string[]
---@field valid boolean

---@param s any
---@return boolean
function M.is_status(s)
  return vim.tbl_contains(M.STATUSES, s)
end

---Read one plan file's text. Always returns a plan; a broken file carries `errors` (`valid = false`). A bare
---`[[slug]]` target is settled by `ctx.link_resolver` (without one it names nothing: `wikilink-dangling`).
---@param text string
---@param ctx { path: string, area: string, slug?: string, location?: "roadmap"|"backlog", kind?: "plan"|"project", folder?: boolean, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile
function M.parse(text, ctx)
  local slug = ctx.slug or model.slug_of(ctx.path, ctx.location or "roadmap")
  local file_kind = ctx.kind or "plan"
  local errors, codes = {}, {}
  ---@param code string
  ---@param msg string
  local function bad(code, msg)
    -- the codes of a project file say `project-...` (a learning path's `path-...`) where a plan's say `plan-...`
    if file_kind ~= "plan" and code:sub(1, 5) == "plan-" then
      code = file_kind .. "-" .. code:sub(6)
    end
    errors[#errors + 1] = msg
    codes[#codes + 1] = code
  end
  ---@type Tasks.PlanFile
  local plan = {
    id = ctx.area .. "/" .. slug,
    kind = file_kind,
    area = ctx.area,
    slug = slug,
    path = fsio.norm(ctx.path),
    location = ctx.location or "roadmap",
    title = slug,
    areas = {},
    phase_order = {},
    links = {},
    tags = {},
    folder = ctx.folder == true,
    summary = "",
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
    -- the tree and the levels count the lines of the body; the file's line is that plus the frontmatter block
    local head = text:sub(1, #text - #(parsed.body or ""))
    plan.body_offset = select(2, head:gsub("\n", ""))
    plan.title = model.field_text(meta.title, "title", bad) or slug
    if meta.title == nil then
      bad("title-missing", "title is missing")
    end
    local status = model.field_text(meta.status, "status", bad)
    if status then
      plan.status = status
      if not M.is_status(status) then
        bad(
          "plan-bad-status",
          ("unknown plan status '%s' (expected %s)"):format(status, table.concat(M.STATUSES, ", "))
        )
      end
    else
      bad("plan-bad-status", "status is missing")
    end
    plan.areas = model.field_list(meta.areas, "areas", bad)
    for _, a in ipairs(plan.areas) do
      if not vault.valid_area(a) then
        bad("plan-bad-area", "areas: invalid area name " .. fsio.clean(a))
      end
    end
    plan.tags = model.field_list(meta.tags, "tags", bad)
    plan.links = model.field_list(meta.links, "links", bad)
    for _, link in ipairs(plan.links) do
      if not model.is_web_link(link) then
        bad(
          "bad-link",
          ("links entry '%s' is not an http:// or https:// address"):format(fsio.clean(link))
        )
      end
    end
    local target = model.field_text(meta.target, "target", bad)
    if target then
      plan.target_raw = vim.trim(target)
      -- an id or an Obsidian wikilink (`tasks_nvim.wikilinks`), read like `blocked_by` / `after` / `plan` of a task
      local kind, value = wikilinks.read(vim.trim(target))
      if kind == "bad" then
        bad("plan-bad-target", "target: " .. value)
      elseif kind == "slug" then
        local ids = ctx.link_resolver and ctx.link_resolver.candidates(value) or {}
        if #ids == 1 then
          plan.target = ids[1]
        else
          plan.link_problems = {
            {
              code = #ids == 0 and "wikilink-dangling" or "wikilink-ambiguous",
              field = "target",
              raw = vim.trim(target),
              candidates = vim.list_slice(ids, 1),
            },
          }
        end
      else
        local _, tslug, terr = vault.parse_id(value)
        if terr or not tslug then
          bad("plan-bad-target", "target: " .. (terr or ("expected <area>/<slug>, got " .. value)))
        else
          plan.target = value
        end
      end
    end
    plan.phase_order = model.field_list(meta.phase_order, "phase_order", bad)
    for _, p in ipairs(plan.phase_order) do
      local phase_err = vault.slug_error("phase_order", p)
      if phase_err then
        bad("bad-phase", phase_err)
      end
    end
    local gate = model.field_text(meta.gate, "gate", bad)
    if gate then
      if gate == "hard" then
        plan.gate = "hard"
      else
        bad("plan-bad-gate", "gate must be `hard` or absent, got '" .. fsio.clean(gate) .. "'")
      end
    end
    if
      file_kind == "path" and (meta.phase_order ~= nil or meta.gate ~= nil or meta.phase ~= nil)
    then
      -- a path organises knowledge, not work: its order is the tree, not stages
      bad(
        "path-no-stages",
        "a learning path has no phase_order, gate or phase: its order is the tree"
      )
    end
    local project = model.field_text(meta.project, "project", bad)
    if file_kind == "project" then
      if meta.project ~= nil or meta.phase ~= nil then
        bad("project-nested", "a project is not part of another project: no project: or phase:")
      end
    else
      if project then
        plan.project_raw = vim.trim(project)
        -- an id or an Obsidian wikilink, read like `target`
        local pkind, value = wikilinks.read(vim.trim(project))
        if pkind == "bad" then
          bad("plan-bad-project", "project: " .. value)
        elseif pkind == "slug" then
          local ids = ctx.link_resolver and ctx.link_resolver.candidates(value) or {}
          if #ids == 1 then
            plan.project = ids[1]
          else
            plan.link_problems = plan.link_problems or {}
            table.insert(plan.link_problems, {
              code = #ids == 0 and "wikilink-dangling" or "wikilink-ambiguous",
              field = "project",
              raw = vim.trim(project),
              candidates = vim.list_slice(ids, 1),
            })
          end
        else
          local _, pslug, pid_err = vault.parse_id(value)
          if pid_err or not pslug then
            bad(
              "plan-bad-project",
              "project: " .. (pid_err or ("expected <area>/<slug>, got " .. value))
            )
          else
            plan.project = value
          end
        end
      end
      local phase = file_kind == "plan" and model.field_text(meta.phase, "phase", bad) or nil
      if phase then
        local phase_err = vault.slug_error("phase", phase)
        if phase_err then
          bad("bad-phase", phase_err)
        else
          plan.phase = phase
        end
      end
    end
    for _, field in ipairs({ "created", "updated" }) do
      local date = model.field_text(meta[field], field, bad)
      if date then
        plan[field] = date
        if not model.is_date(date) then
          bad("bad-date", ("%s '%s' is not a date (YYYY-MM-DD)"):format(field, date))
        end
      end
    end
    plan.summary = model.field_text(meta.summary, "summary", bad)
      or model.first_paragraph(parsed.body)
    local icon_text = model.field_text(meta.icon, "icon", bad)
    if icon_text then
      local icon, icon_err = model.icon_of(icon_text)
      if icon then
        plan.icon = icon
      else
        bad("bad-icon", icon_err)
      end
    end
    local cover = model.field_text(meta.cover, "cover", bad)
    if cover then
      local cover_err = model.asset_error(cover, "cover")
      if cover_err then
        bad("bad-cover", cover_err)
      else
        plan.cover = cover
      end
    end
    if file_kind == "path" then
      -- the problems of the tree are `check`'s findings, never a fault of the file (R3: nothing refuses a write)
      plan.tree = require("tasks_nvim.lernbaum").parse(parsed.body or "")
      plan.levels = require("tasks_nvim.lernlevel").parse(parsed.body or "")
    end
  end
  if file_kind == "path" and not plan.tree then
    plan.tree = require("tasks_nvim.lernbaum").parse("")
  end
  if file_kind == "path" and not plan.levels then
    plan.levels = require("tasks_nvim.lernlevel").parse("")
  end
  plan.valid = #errors == 0
  return plan
end

---Read a plan file from disk.
---@param path string
---@param ctx { area: string, slug?: string, location?: "roadmap"|"backlog", kind?: "plan"|"project", folder?: boolean, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile
function M.from_file(path, ctx)
  local text, err = fsio.read(path)
  if not text then
    local plan = M.parse("", vim.tbl_extend("force", { path = path }, ctx))
    plan.errors = { "cannot read file: " .. tostring(err) }
    plan.error_codes = { "unreadable" }
    plan.valid = false
    return plan
  end
  return M.parse(text, vim.tbl_extend("force", { path = path }, ctx))
end

---The open plans of an area (`ROADMAP/plans/<slug>.md` and `ROADMAP/plans/<slug>/<slug>.md`), by slug. A bare `[[slug]]` target is settled over the vault
---(`opts.link_resolver`, else one made here; its index is built only when a target needs it).
---@param area string
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile[]|nil plans
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
  local dir = vault.plans_dir(root, area)
  local out = {}
  if not fsio.is_dir(dir) then
    return out, {}
  end
  local escape = vault.leaves(root, dir)
  if escape then
    return out, { escape }
  end
  local resolver = opts.link_resolver or wikilinks.resolver(root)
  for _, e in ipairs(vault.plan_files(dir)) do
    out[#out + 1] = M.from_file(
      e.path,
      { area = area, slug = e.slug, folder = e.folder, link_resolver = resolver }
    )
  end
  return out, {}
end

---Every open plan of the vault.
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile[]|nil plans
---@return string|nil err
function M.all(opts)
  opts = opts or {}
  local root, err = vault.root(opts)
  if not root then
    return nil, err
  end
  local out = {}
  local resolver = opts.link_resolver or wikilinks.resolver(root)
  for _, a in ipairs(vault.areas(root)) do
    local plans = M.area(a.name, { root = root, link_resolver = resolver })
    for _, plan in ipairs(plans or {}) do
      out[#out + 1] = plan
    end
  end
  return out, nil
end

---An open plan by id.
---@param id string
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile|nil plan
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
  -- Not an area, or one spelled in another case (`LIB.NVIM/x` would find `lib.nvim/x` on a case-insensitive disk,
  -- under a second id; `plans.members` compares ids as strings and would close the plan with members still open).
  if not vault.has_area(root, area) then
    return nil, "no such open plan: " .. id
  end
  local path, folder = vault.resolve_plan(root, "plan", area, slug)
  if not path then
    return nil, folder --[[@as string]]
  end
  return M.from_file(path, {
    area = area,
    slug = slug,
    folder = folder == true,
    link_resolver = opts.link_resolver or wikilinks.resolver(root),
  }),
    nil
end

---The assets of a plan or project file in its folder form (`<slug>/<slug>.md`): every other file below that folder, as a
---path relative to it (`assets/shot.png`), sorted; at most `limit` (default 100), `truncated` beyond. A plain file has
---none.
---@param file Tasks.PlanFile
---@param limit? integer
---@return string[] assets
---@return boolean truncated
function M.assets(file, limit)
  limit = limit or 100
  if not file.folder then
    return {}, false
  end
  local dir = fsio.dirname(file.path)
  local own = vim.fs.basename(file.path)
  local out = {}
  for name, kind in vim.fs.dir(dir, { depth = 4 }) do
    if kind == "file" and name ~= own then
      out[#out + 1] = (name:gsub("\\", "/"))
    end
  end
  table.sort(out)
  if #out > limit then
    return vim.list_slice(out, 1, limit), true
  end
  return out, false
end

---The open tasks that belong to a plan (`plan: <id>`).
---@param plan_id string
---@param tasks Tasks.Task[]
---@return Tasks.Task[]
function M.members(plan_id, tasks)
  local out = {}
  for _, t in ipairs(tasks) do
    if t.plan == plan_id then
      out[#out + 1] = t
    end
  end
  return out
end

---@class Tasks.PlanSummary
---@field title? string
---@field tasks integer
---@field days number
---@field n_without_effort integer
---@field days_taken? integer

---What a finished plan amounted to, for the message: its finished member tasks (across the areas it lists, else every
---area), their effort on the scale and the days from `created` to `date`.
---@param file Tasks.PlanFile
---@param opts? { root?: string, date?: string }
---@return Tasks.PlanSummary
function M.summary(file, opts)
  opts = opts or {}
  local root = vault.root(opts)
  local areas = {}
  if #file.areas > 0 then
    areas = vim.list_extend({ file.area }, file.areas)
  elseif root then
    for _, a in ipairs(vault.areas(root)) do
      areas[#areas + 1] = a.name
    end
  end
  local seen, out = {}, { tasks = 0, days = 0, n_without_effort = 0 }
  for _, area in ipairs(areas) do
    if not seen[area] then
      seen[area] = true
      for _, t in ipairs(scan.backlog(area, { root = root }) or {}) do
        if t.plan == file.id then
          out.tasks = out.tasks + 1
          local days = model.effort_days(t.effort)
          if days then
            out.days = out.days + days
          else
            out.n_without_effort = out.n_without_effort + 1
          end
        end
      end
    end
  end
  local from = file.created and model.days_between(file.created, opts.date or model.today())
  out.days_taken = from
  return out
end

---The longest slug of a plan (the file name has room for `-NN` and `.md`).
M.MAX_SLUG = 200

---The line of a template that stands for the generated overview of a project (`overview_block`): replaced when the
---file is written, never written itself.
M.OVERVIEW_SLOT = "<!-- tasks-nvim:overview-slot -->"

---The stages a learning plan proposes (`template = "learning"`); free to change.
---@type string[]
M.LEARNING_PHASES = { "orientieren", "grundlagen", "vertiefen", "anwenden", "festigen" }

---The bodies of `template`, per kind of file (Lernplan-Konzept §5): a plan keeps it short, a path carries the sections a
---learner works through, with the tree in `## Lernpunkte`.
---@type table<string, table<string, string[]>>
M.TEMPLATES = {
  learning = {
    plan = {
      "## Ziel und Kompetenzstufe",
      "",
      "<!-- Ziel in einem Satz; Kompetenzziel (T/P-Stufe); Ergebnis-Artefakt. -->",
      "",
      "## Definition of done",
      "",
      "<!-- Selbstcheck bestanden, Ergebnis geschrieben und verlinkt, offene Fragen gestellt. -->",
      "",
      "## Entscheidungen",
      "",
      "<!-- Verweise auf decision-Tasks, nicht kopieren. -->",
      "",
      "## Notizen",
      "",
    },
    path = {
      "## Ziel und Kompetenzstufe",
      "",
      "<!-- Ziel in einem Satz; Kompetenzziel (T/P-Stufe); Status und Datum; Ergebnis-Artefakt. -->",
      "",
      "## Zugang",
      "",
      "<!-- Welcher Zugang fehlt, was ersatzweise geht (Demo, Logs, Screenshots). -->",
      "",
      "## Zeitplan",
      "",
      "| Sitzung | Dauer | Ergebnis |",
      "| --- | --- | --- |",
      "",
      "## Quellen",
      "",
      "<!-- Typ: Doku, Academy, KB, Fall, Buch, Video; Zugang: frei, Login, intern, lokal; Geprüft: Datum der Prüfung oder „ungeprüft“ (LP-07). Je Quelle ein Punkt im Baum, der sie verlinkt. -->",
      "",
      "| Quelle | Typ | Worauf achten | Zugang | Geprüft |",
      "| --- | --- | --- | --- | --- |",
      "",
      "## Lernpunkte",
      "",
      "<!-- Stufen als oberste Punkte, in dieser Reihenfolge (LP-06): Stufe 0 · Orientieren {#orientieren}, Stufe 1 · Grundlagen {#grundlagen}, Stufe 2 · Vertiefen {#vertiefen}, Stufe 3 · Anwenden {#anwenden}, Stufe 4 · Festigen {#festigen}; weglassen ja, umbenennen nein. -->",
      "<!-- Literatur als letzte Gruppe (LP-11): - [ ] Hintergrund aus der Literatur (je Buch nur das Kapitel zur Frage) {optional} {#literatur}, darunter je Buch ein Punkt mit Link und der Frage, die es beantwortet ({optional}: zählt nicht für Fortschritt, Prozent-Level und „Pfad fertig“, die XP gelesener Bücher schon); danach eine Zeile „Fehlt im Bestand: …“ für die Beschaffungsliste. -->",
      '<!-- - [ ] Punkt {#schluessel}: [x] gelernt, [~] angeschaut, [-] entfaellt (mit "– Grund: ..."), [!] blockiert -->',
      "",
      "## Level",
      "",
      "<!-- Freiwillig (LP-18): ohne diesen Abschnitt ist der Pfad vollständig. Je Zeile eine Schwelle, etwa: -->",
      "<!-- - [ ] 50 XP · Erster Schritt · Badge assets/badges/erster-schritt.svg · Belohnung: … -->",
      "<!-- - [ ] 50 % · Halbzeit · Belohnung: … -->",
      "<!-- - [ ] Pfad fertig · T 2 / P 2 · Belohnung: … -->",
      "",
      "## Selbstcheck",
      "",
      "<!-- 8 bis 12 Fragen, schriftlich, ohne Notizen. -->",
      "",
      "## Offene Fragen",
      "",
      "<!-- An wen, bis wann; spaeter mit Antwort. -->",
      "",
      "## Wiederholung",
      "",
      "<!-- Termine und welche Fragen wieder. -->",
      "",
      "## Ergebnis schreiben",
      "",
      "<!-- Was der Pfad ergibt, fließt in die Sammelnotizen zurück (LP-15): Terminologie, DocLinks, Portfolio-Notiz, Support-Scope; je Ziel eine Zeile. -->",
      "",
      "## Notizen",
      "",
    },
    -- a curriculum of several learning paths (LP-01): the paths hang in it with `project:`, their table is generated
    project = {
      "## Ziel und Abgrenzung",
      "",
      "<!-- Was das Lernvorhaben als Ganzes erreichen soll, in einem Satz; was nicht dazugehört. -->",
      "<!-- Kompetenzziel: Zeile der Kompetenzmatrix, heute → Ziel (T/P-Stufe); Abschlussprojekt oder Ergebnis-Artefakt. -->",
      "",
      "## Lernpfade",
      "",
      '<!-- Ein Pfad hängt mit project: am Projekt (tasks path-new <area> "<Titel>" --project=<id> --template=learning, oder tasks set <pfad> project=<id>). Die Tabelle erzeugt tasks projects --of=<id> --write=<diese Datei> neu; tasks paths --project=<id> zeigt sie in der Shell. -->',
      M.OVERVIEW_SLOT,
      "",
      "## Takt",
      "",
      "<!-- Stunden pro Woche; je Woche Lesen (Primärquelle), Code lesen, Selbst bauen, Nachweis; Mindestweg und voller Weg. -->",
      "",
      "## Definition of done",
      "",
      "<!-- - [ ] Alle Pfade mit Selbstcheck bestanden (LP-13), Wiederholungen eingeplant (LP-14) -->",
      "<!-- - [ ] Abschlussprojekt fertig und gegen die Regeln geprüft -->",
      "<!-- - [ ] Kompetenzmatrix mit Nachweisen neu eingestuft -->",
      "",
      "## Entscheidungen",
      "",
      "<!-- Verweise auf decision-Tasks, nicht kopieren. -->",
      "",
      "## Notizen",
      "",
    },
  },
}

---Make the generated overview block of a new project (the slot of the learning template): the marker pair with the
---project's id (`overview=<id>`, scope its slug, the name `projects --of` takes by default) around the overview of an
---empty project, so the first `projects --of=<id> --write=<file>` finds the block. Pure.
---@param id string
---@param slug string
---@param project { title: string, status: string, phase_order: string[], target?: string }
---@return string
local function overview_block(id, slug, project)
  local plan_view = require("tasks_nvim.plan_view")
  local start, finish = plan_view.block_markers(slug, { overview = id })
  local body = require("tasks_nvim.projects").overview(
    vim.tbl_extend("force", project, { id = id }),
    { plans = {}, open = {}, finished = {}, paths = {} }
  )
  return start .. "\n" .. body .. finish
end

---@class Tasks.NewPlanOpts
---@field root? string
---@field reserved? table<string, true>   # A dry run of `tasks-ops/1`: ids earlier operations of the request take.
---@field pending_files? table<string, Tasks.PendingFile> # A dry run: plans and projects earlier operations would create.
---@field title string
---@field areas? string[]|string
---@field target? string          # A task id or a wikilink to it (`[[<slug>]]`, `[[<area>/<slug>]]`, a vault path).
---@field links? "plain"|"wikilink" # How an id `target` is written (default: `setup({ links })`, `$TASKS_LINKS`).
---@field link_resolver? Tasks.LinkResolver
---@field phases? string[]|string
---@field gate? string
---@field status? string
---@field summary? string
---@field slug? string
---@field web_links? string[]|string  # Web addresses for `links:` (http/https; a text is split at commas).
---@field tags? string[]|string     # `tags:` (a text is split at commas).
---@field icon? string            # `icon:`: an emoji, a file below `assets/` or a word (`model.icon_of`).
---@field cover? string           # `cover:`: a picture below `assets/`.
---@field today? string
---@field dry_run? boolean  # Name the plan the call would make and write nothing.
---@field template? "learning"  # The body (and, for a plan without `phases`, the stages) of a learning plan or path.

---Create `<area>/ROADMAP/plans/<slug>.md` (never overwrites; a taken slug gets `-2`, `-3`, ...). Plans, open tasks and
---Backlog files share ONE id namespace per area: a finished plan lands in `Backlog/FEATURES` and would read as a
---finished task of that id, so a slug held by a task (file or folder), a finished item or another plan is taken.
---@param area string
---@param opts Tasks.NewPlanOpts
---@return { id: string, path: string, slug: string, renamed: boolean, ambiguous?: Tasks.NewAmbiguity }|nil result  # `renamed`: the slug asked for (or made of the title) was taken; `ambiguous`: the bare `[[slug]]` links the new plan made ambiguous (`wikilinks.new_ambiguity`)
---@return string|nil err
---@return table|nil info  # `{ code = "invalid_argument" }` for a project or stage that is wrong
function M.new(area, opts)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  if not vault.has_area(root, area) then
    return nil, "unknown area: " .. tostring(area)
  end
  local title = type(opts.title) == "string" and vim.trim(fsio.clean(opts.title)) or ""
  if title == "" or title:find("[\r\n]") then
    return nil, "title must be one non-empty line"
  end
  local status = opts.status or "planning"
  if not M.is_status(status) or status == "done" then
    return nil,
      ("unknown plan status '%s' (expected planning, doing or parked)"):format(tostring(status))
  end
  local function list(value, what)
    if value == nil then
      return {}, nil
    end
    local out = {}
    local items = type(value) == "table" and value
      or vim.split(tostring(value), ",", { plain = true })
    for _, item in ipairs(items) do
      local t = vim.trim(tostring(item))
      if t ~= "" then
        if t:find("[,%[%]\"'#]") then
          return nil, what .. " item '" .. t .. "' must not contain , [ ] quotes or #"
        end
        out[#out + 1] = t
      end
    end
    return out, nil
  end
  local tags, tags_err = list(opts.tags, "tags")
  if not tags then
    return nil, tags_err, { code = "invalid_argument" }
  end
  local areas, aerr = list(opts.areas, "areas")
  if not areas then
    return nil, aerr
  end
  for _, a in ipairs(areas) do
    if not vault.valid_area(a) then
      return nil, "areas: invalid area name " .. a
    end
  end
  if opts.template ~= nil and not M.TEMPLATES[opts.template] then
    return nil,
      ("unknown template '%s' (expected learning)"):format(tostring(opts.template)),
      { code = "invalid_argument" }
  end
  local phases, perr = list(opts.phases, "phases")
  if not phases then
    return nil, perr
  end
  -- a learning plan proposes its stages; a path has none, and phases given win
  if
    opts.template == "learning"
    and #phases == 0
    and opts.kind ~= "path"
    and opts.kind ~= "project"
  then
    phases = vim.list_slice(M.LEARNING_PHASES, 1)
  end
  for _, p in ipairs(phases) do
    local serr, details = vault.slug_error("phase", p)
    if serr then
      return nil, serr, { code = "invalid_argument", details = details }
    end
  end
  -- the target as an id (a wikilink resolved), written as typed when it was a wikilink, else in the form `links`
  -- asks for (`tasks_nvim.wikilinks.render`), like `plan` / `after` of `new`
  local target_text
  -- One link index for the target and for the ambiguity of the new slug (it leaves the new id out either way).
  local link_resolver = opts.link_resolver
  if opts.target ~= nil then
    local raw = vim.trim(tostring(opts.target))
    link_resolver = link_resolver or wikilinks.resolver(root)
    local resolver = link_resolver
    local tid, terr = wikilinks.typed_id(raw, "target", resolver)
    if not tid then
      return nil, terr
    end
    target_text = wikilinks.is_wikilink(raw) and raw
      or wikilinks.render(tid, wikilinks.mode(opts), resolver)
  end
  if opts.gate ~= nil and opts.gate ~= "hard" then
    return nil, "gate must be `hard` or absent"
  end
  -- a project file is made the same way (`opts.kind = "project"`), a learning path too (`"path"`); a plan may name
  -- its project and its stage there, a path its project only
  local file_kind = (opts.kind == "project" or opts.kind == "path") and opts.kind or "plan"
  if file_kind == "path" and (#phases > 0 or opts.gate ~= nil or opts.phase ~= nil) then
    return nil,
      "a learning path has no stages: no phases, gate or phase (its order is the tree)",
      { code = "invalid_argument" }
  end
  local project_text, phase_text
  if opts.project ~= nil or opts.phase ~= nil then
    if file_kind == "project" then
      return nil,
        "a project is not part of another project: no project or phase",
        { code = "invalid_argument" }
    end
    if opts.project == nil then
      return nil,
        "phase names a stage of a project: give the project, too",
        { code = "invalid_argument" }
    end
    local raw = vim.trim(tostring(opts.project))
    if raw:find("[\r\n]") then
      return nil, "project must be one line", { code = "invalid_argument" }
    end
    link_resolver = link_resolver or wikilinks.resolver(root)
    local pid, perr2 = wikilinks.typed_id(raw, "project", link_resolver)
    if not pid then
      return nil, perr2, { code = "invalid_argument" }
    end
    local project_file = require("tasks_nvim.projects").find(pid, { root = root })
    -- a dry run: a project an earlier `project_new` of the same request would create
    local pending = opts.pending_files and opts.pending_files[pid]
    if not project_file and pending and pending.kind == "project" then
      project_file = pending
    end
    if not project_file then
      return nil, "no such open project: " .. pid, { code = "invalid_argument" }
    end
    if opts.phase ~= nil then
      local phase = vim.trim(tostring(opts.phase))
      local serr, details = vault.slug_error("phase", phase)
      if serr then
        return nil, serr, { code = "invalid_argument", details = details }
      end
      if
        #project_file.phase_order > 0 and not vim.tbl_contains(project_file.phase_order, phase)
      then
        return nil,
          ("phase '%s' is not in the phase_order of %s (%s)"):format(
            phase,
            pid,
            table.concat(project_file.phase_order, ", ")
          ),
          { code = "invalid_argument" }
      end
      phase_text = phase
    end
    project_text = wikilinks.is_wikilink(raw) and raw
      or wikilinks.render(pid, wikilinks.mode(opts), link_resolver)
  end
  local dir_of = vault.file_kind_dir(file_kind)
  local function path_of(r, a, s)
    return vault.file_kind_path(file_kind, r, a, s)
  end
  local today = opts.today or model.today()
  if not model.is_date(today) then
    return nil, "today is not a date (YYYY-MM-DD): " .. tostring(today)
  end
  local base = opts.slug or require("tasks_nvim.mutate").slugify(title)
  local slug_err, slug_details = vault.slug_error("slug", base)
  if slug_err then
    return nil, slug_err, { code = "invalid_argument", details = slug_details }
  end
  if vault.is_reserved_name(base) then
    return nil, ("slug '%s' is a reserved Windows device name"):format(base)
  end
  if #base > M.MAX_SLUG then
    return nil, ("slug is longer than %d characters"):format(M.MAX_SLUG)
  end
  local web_links = {}
  if opts.web_links ~= nil then
    local given, lerr = require("tasks_nvim.mutate").link_list(opts.web_links)
    if not given then
      return nil, lerr, { code = "invalid_argument" }
    end
    web_links = given
  end
  local mutate = require("tasks_nvim.mutate")
  local icon, cover
  if opts.icon ~= nil then
    local ierr
    icon, ierr = mutate.icon_field(opts.icon)
    if icon == nil then
      return nil, ierr, { code = "invalid_argument" }
    end
  end
  if opts.cover ~= nil then
    local cerr
    cover, cerr = mutate.cover_field(opts.cover)
    if cover == nil then
      return nil, cerr, { code = "invalid_argument" }
    end
  end

  local pairs_ = { { "title", title }, { "status", status } }
  if #areas > 0 then
    pairs_[#pairs_ + 1] = { "areas", areas }
  end
  if #tags > 0 then
    pairs_[#pairs_ + 1] = { "tags", tags }
  end
  if target_text then
    pairs_[#pairs_ + 1] = { "target", target_text }
  end
  if #phases > 0 then
    pairs_[#pairs_ + 1] = { "phase_order", phases }
  end
  if opts.gate then
    pairs_[#pairs_ + 1] = { "gate", opts.gate }
  end
  if project_text then
    pairs_[#pairs_ + 1] = { "project", project_text }
  end
  if phase_text then
    pairs_[#pairs_ + 1] = { "phase", phase_text }
  end
  if #web_links > 0 then
    pairs_[#pairs_ + 1] = { "links", web_links }
  end
  if icon then
    pairs_[#pairs_ + 1] = { "icon", icon }
  end
  if cover then
    pairs_[#pairs_ + 1] = { "cover", cover }
  end
  pairs_[#pairs_ + 1] = { "created", today }
  pairs_[#pairs_ + 1] = { "updated", today }
  local lead = opts.summary and (vim.trim(opts.summary) .. "\n\n") or ""
  local sections = opts.template == "learning" and M.TEMPLATES.learning[file_kind]
    or file_kind == "path" and {
      "## Warum",
      "",
      "<!-- Wozu dieser Lernpfad dient, und woran man merkt, dass man es kann. -->",
      "",
      "## Lernpunkte",
      "",
      '<!-- - [ ] Punkt {#schluessel}: [x] gelernt, [~] angeschaut, [-] entfaellt (mit "– Grund: ..."), [!] blockiert -->',
      "",
      "## Notizen",
      "",
    }
    or nil
  local body = "\n"
    .. lead
    .. table.concat(sections or {
      "## Ziel und Abgrenzung",
      "",
      "<!-- Was dieses Vorhaben erreichen soll, und was nicht dazugehoert. -->",
      "",
      "## Definition of done",
      "",
      "<!-- Wann ist es fertig? -->",
      "",
      "## Entscheidungen",
      "",
      "<!-- Verweise auf decision-Tasks, nicht kopieren. -->",
      "",
      "## Notizen",
      "",
    }, "\n")
  local text, ferr = fm.update_text(body, pairs_, { create = true })
  if not text then
    return nil, "cannot build the plan file: " .. tostring(ferr)
  end

  if not opts.dry_run then
    local mkdir_ok, mkerr = fsio.mkdirp(dir_of(root, area))
    if not mkdir_ok then
      return nil, "cannot create " .. dir_of(root, area) .. ": " .. tostring(mkerr)
    end
  end
  local backlog_taken, berr = scan.backlog_slugs(area, { root = root })
  if not backlog_taken then
    return nil, berr
  end
  local n = 1
  while n < 1000 do
    local slug = n == 1 and base or (base .. "-" .. n)
    local path = path_of(root, area, slug)
    -- the learning template of a project carries its own overview block: it names the id this slug gives
    local file_text = text
    local slot = file_text:find(M.OVERVIEW_SLOT, 1, true)
    if slot then
      file_text = file_text:sub(1, slot - 1)
        .. overview_block(area .. "/" .. slug, slug, {
          title = title,
          status = status,
          phase_order = phases,
          target = target_text,
        })
        .. file_text:sub(slot + #M.OVERVIEW_SLOT)
    end
    -- plans, projects and tasks share one id namespace
    local held = backlog_taken[slug] ~= nil
      or fsio.is_file(vault.task_path(root, area, slug))
      or fsio.is_dir(vault.task_dir(root, area, slug))
      or vault.has_plan_or_project(root, area, slug)
      -- a folder of that name (the folder form of a plan or project, or a leftover) would hold a second file
      or fsio.is_dir(dir_of(root, area) .. "/" .. slug)
      or (opts.dry_run and (fsio.is_file(path) or fsio.is_dir(path)))
      -- a dry run: the ids earlier operations of the same request take (`tasks-ops/1`), as the real run has them
      or (opts.reserved ~= nil and opts.reserved[area .. "/" .. slug] ~= nil)
    if not held and opts.dry_run then
      return {
        id = area .. "/" .. slug,
        path = path,
        slug = slug,
        renamed = n > 1,
        phase_order = phases,
      },
        nil
    end
    if not held then
      local ok, err = fsio.create_exclusive(path, file_text)
      if ok then
        local id = area .. "/" .. slug
        -- The link index holds the plan files too: a slug another area has makes its `[[slug]]` links ambiguous.
        local resolver = link_resolver or wikilinks.resolver(root)
        return {
          id = id,
          path = path,
          slug = slug,
          renamed = n > 1,
          ambiguous = wikilinks.new_ambiguity(root, resolver, id, slug),
        },
          nil
      end
      if not fsio.is_exists(err) then
        return nil, "cannot create " .. path .. ": " .. tostring(err)
      end
    end
    n = n + 1
  end
  return nil, "no free file name for plan " .. base
end

---The keys `set` may change in a plan file or a project file.
---@type table<string, string[]>
M.SET_KEYS = {
  plan = {
    "title",
    "status",
    "areas",
    "target",
    "phase_order",
    "gate",
    "project",
    "phase",
    "links",
    "icon",
    "cover",
  },
  project = {
    "title",
    "status",
    "areas",
    "target",
    "phase_order",
    "gate",
    "links",
    "icon",
    "cover",
  },
  path = { "title", "status", "areas", "target", "project", "links", "icon", "cover", "tags" },
}

---The finder of a kind of file: plans here, projects and paths in their own modules (required where used: they
---require this module).
---@param file_kind "plan"|"project"|"path"
---@return fun(id: string, opts?: table): Tasks.PlanFile|nil, string|nil
local function finder_of(file_kind)
  if file_kind == "project" then
    return require("tasks_nvim.projects").find
  elseif file_kind == "path" then
    return require("tasks_nvim.paths").find
  end
  return M.find
end

---Change the frontmatter of an open plan file or project file (`opts.kind = "project"`). `patch` maps a key of
---`SET_KEYS` to its new value; `nil`, `vim.NIL`, an empty text or an empty list removes the key (not `title` and
---`status`). A plan finishes with `close`, not by `status: done`. The file is judged as it would read afterwards: a
---fault the change brings (a bad status, a gate that is not `hard`, a phase without a project, a project that is none,
---a stage the project does not list) refuses it and nothing is written; a fault the file had already is not the
---change's. `opts.if_match` is the version tag the caller read.
---@param id string
---@param patch table<string, any>
---@param opts? { root?: string, today?: string, kind?: "plan"|"project", if_match?: string, dry_run?: boolean, link_resolver?: Tasks.LinkResolver }
---@return { id: string, path: string, etag_before: string, etag_after: string, changed: boolean, before: table<string, any> }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict", problems? }`
function M.set(id, patch, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local file_kind = (opts.kind == "project" or opts.kind == "path") and opts.kind or "plan"
  local file, ferr = finder_of(file_kind)(id, { root = root, link_resolver = opts.link_resolver })
  if not file then
    return nil, ferr, { code = "not_found" }
  end
  local mutate = require("tasks_nvim.mutate")
  local allowed = {}
  for _, key in ipairs(M.SET_KEYS[file_kind]) do
    allowed[key] = true
  end
  local keys = vim.tbl_keys(patch)
  table.sort(keys)
  if #keys == 0 then
    return nil, "the patch is empty", { code = "invalid_argument" }
  end
  local resolver = opts.link_resolver or wikilinks.resolver(root)
  local pairs_ = {}
  for _, key in ipairs(keys) do
    if not allowed[key] then
      return nil,
        ("unknown field '%s' (settable: %s)"):format(
          tostring(key),
          table.concat(M.SET_KEYS[file_kind], ", ")
        ),
        { code = "invalid_argument" }
    end
    local value = patch[key]
    local remove = value == nil
      or value == vim.NIL
      or value == ""
      or (type(value) == "table" and #value == 0)
    if remove then
      if key == "title" or key == "status" then
        return nil, key .. " cannot be removed", { code = "invalid_argument" }
      end
      pairs_[#pairs_ + 1] = { key, mutate.REMOVE }
    elseif key == "areas" or key == "phase_order" or key == "tags" then
      local items = type(value) == "table" and value
        or vim.split(tostring(value), ",", { plain = true })
      local list = {}
      for _, item in ipairs(items) do
        local text = vim.trim(tostring(item))
        if text ~= "" then
          if text:find("[,%[%]\"'#\r\n]") then
            return nil,
              key .. " item '" .. text .. "' must not contain , [ ] quotes # or a line break",
              { code = "invalid_argument" }
          end
          if key == "phase_order" then
            local serr, details = vault.slug_error("phase", text)
            if serr then
              return nil, serr, { code = "invalid_argument", details = details }
            end
          end
          list[#list + 1] = text
        end
      end
      pairs_[#pairs_ + 1] = { key, list }
    elseif key == "links" then
      local list, lerr = mutate.link_list(value)
      if not list then
        return nil, lerr, { code = "invalid_argument" }
      end
      pairs_[#pairs_ + 1] = { key, list }
    elseif key == "icon" or key == "cover" then
      local stored, ierr = (key == "icon" and mutate.icon_field or mutate.cover_field)(value)
      if stored == nil then
        return nil, ierr, { code = "invalid_argument" }
      end
      pairs_[#pairs_ + 1] = { key, stored }
    else
      if type(value) ~= "string" then
        return nil, key .. " must be a text", { code = "invalid_argument" }
      end
      local text = vim.trim(value)
      if text:find("[\r\n]") then
        return nil, key .. " must be one line", { code = "invalid_argument" }
      end
      if key == "status" and text == "done" then
        return nil,
          "a plan or project is finished with close, not with status done",
          { code = "invalid_argument" }
      end
      if key == "project" then
        local pid, perr = wikilinks.typed_id(text, "project", resolver)
        if not pid then
          return nil, perr, { code = "invalid_argument" }
        end
        pairs_[#pairs_ + 1] = { key, wikilinks.is_wikilink(text) and text or pid }
      elseif key == "phase" then
        local serr, details = vault.slug_error("phase", text)
        if serr then
          return nil, serr, { code = "invalid_argument", details = details }
        end
        pairs_[#pairs_ + 1] = { key, text }
      else
        pairs_[#pairs_ + 1] = { key, text }
      end
    end
  end

  -- the relation of a plan (or a path) to its project, as it would be afterwards
  if file_kind ~= "project" and (patch.project ~= nil or patch.phase ~= nil) then
    local project_id, phase = file.project, file.phase
    for _, kv in ipairs(pairs_) do
      if kv[1] == "project" then
        project_id = kv[2] ~= mutate.REMOVE and wikilinks.typed_id(kv[2], "project", resolver)
          or nil
      elseif kv[1] == "phase" then
        phase = kv[2] ~= mutate.REMOVE and kv[2] or nil
      end
    end
    local problem
    if phase and not project_id then
      problem = {
        code = "plan-phase-without-project",
        key = "phase",
        target = phase,
        message = "phase " .. phase .. " names a stage of a project, but the plan has no project",
      }
    elseif project_id then
      local project_file = require("tasks_nvim.projects").find(project_id, { root = root })
      if not project_file then
        problem = {
          code = "plan-project-unknown",
          key = "project",
          target = project_id,
          message = "no such open project: " .. project_id,
        }
      elseif
        phase
        and #project_file.phase_order > 0
        and not vim.tbl_contains(project_file.phase_order, phase)
      then
        problem = {
          code = "plan-project-phase",
          key = "phase",
          target = phase,
          message = ("phase '%s' is not in the phase_order of %s (%s)"):format(
            phase,
            project_id,
            table.concat(project_file.phase_order, ", ")
          ),
        }
      end
    end
    if problem then
      return nil, problem.message, { code = "invalid_argument", problems = { problem } }
    end
  end

  local today = opts.today or model.today()
  local result = { id = file.id, path = file.path }
  local ok, werr, winfo = fsio.with_lock(file.path, function()
    local cur, rd_err = fsio.read(file.path)
    if not cur then
      return nil, "cannot read " .. file.path .. ": " .. tostring(rd_err)
    end
    local etag = fsio.etag(cur)
    result.etag_before = etag
    if opts.if_match ~= nil and opts.if_match ~= etag then
      return nil,
        ("%s is not the version the change was made on (it is %s, the change was made on %s)"):format(
          file.id,
          etag,
          tostring(opts.if_match)
        ),
        { code = "conflict", id = file.id, expected = opts.if_match, actual = etag }
    end
    local parsed = fm.parse(cur)
    local before = {}
    for _, kv in ipairs(pairs_) do
      local old = parsed and parsed.has_block and fm.get(parsed, kv[1]) or nil
      before[kv[1]] = old == nil and vim.NIL or old
    end
    result.before = before
    local text, uerr = fm.update_text(cur, pairs_)
    if not text then
      return nil,
        "cannot change " .. file.path .. ": " .. tostring(uerr),
        { code = "invalid_argument" }
    end
    if text ~= cur then
      text = fm.update_text(text, { { "updated", today } }) or text
      -- judged as it would read: only the faults the change brings are its own
      local after = M.parse(text, {
        path = file.path,
        area = file.area,
        slug = file.slug,
        kind = file_kind,
        folder = file.folder,
        link_resolver = resolver,
      })
      local known = {}
      for _, code in ipairs(file.error_codes) do
        known[code] = true
      end
      for i, code in ipairs(after.error_codes) do
        if not known[code] then
          return nil, after.errors[i], { code = "invalid_argument" }
        end
      end
    end
    result.etag_after = fsio.etag(text)
    result.changed = text ~= cur
    if opts.dry_run or not result.changed then
      return true
    end
    local wrote, wr_err = fsio.write_atomic(file.path, text)
    if not wrote then
      return nil, "cannot write " .. file.path .. ": " .. tostring(wr_err)
    end
    return true
  end)
  if not ok then
    return nil, werr, winfo
  end
  return result, nil
end

---Finish a plan or project in its folder form: the folder moves to `Backlog/FEATURES/<date>_<slug>/` with its assets,
---the file in it becomes `<date>_<slug>.md` with the finished text, then the README gets its row. A failing step puts
---the folder back as it was (old file name, old text).
---@param plan Tasks.PlanFile
---@param c { id: string, old_text: string, new_text: string, target: string, rel: string, readme_path: string, readme_old?: string, readme_new?: string, readme_row: string, readme_state: string }
---@return { id: string, from: string, to: string, readme: string }|nil result
---@return string|nil err
local function close_folder(plan, c)
  local mutate = require("tasks_nvim.mutate")
  local src_dir, target_dir = fsio.dirname(plan.path), fsio.dirname(c.target)
  local old_name = target_dir .. "/" .. plan.slug .. ".md"
  local changed_msg = plan.path
    .. " changed while it was being finished; nothing was changed, run it again"
  if fsio.read(plan.path) ~= c.old_text then
    return nil, changed_msg
  end
  local made, merr = fsio.mkdirp(fsio.dirname(target_dir))
  if not made then
    return nil, "cannot create " .. fsio.dirname(target_dir) .. ": " .. tostring(merr)
  end
  local moved, mverr = fsio.rename(src_dir, target_dir)
  if not moved then
    return nil, "cannot move " .. src_dir .. ": " .. tostring(mverr)
  end
  local created = false
  ---@param msg string
  local function back(msg)
    local stuck = {}
    if created then
      local gone, gerr = fsio.remove(c.target)
      if not gone then
        stuck[#stuck + 1] = c.target .. " (" .. tostring(gerr) .. ")"
      end
    end
    if not fsio.is_file(old_name) then
      local put, perr = fsio.create_exclusive(old_name, c.old_text)
      if not put then
        stuck[#stuck + 1] = old_name .. " (" .. tostring(perr) .. ")"
      end
    end
    local returned, rerr = fsio.rename(target_dir, src_dir)
    if not returned then
      stuck[#stuck + 1] = target_dir .. " (" .. tostring(rerr) .. ")"
    end
    if #stuck > 0 then
      msg = msg .. " (rollback incomplete: " .. table.concat(stuck, ", ") .. ")"
    end
    return nil, msg
  end
  if fsio.is_file(c.target) then
    return back("target exists: " .. c.target)
  end
  local wrote, werr = fsio.create_exclusive(c.target, c.new_text)
  if not wrote then
    return back("cannot create " .. c.target .. ": " .. tostring(werr))
  end
  created = true
  -- looked at once more right before the original goes: an edit made meanwhile would be dropped with it
  if fsio.read(old_name) ~= c.old_text then
    return back(changed_msg)
  end
  local removed, rm_err = fsio.remove(old_name)
  if not removed then
    return back("cannot remove " .. old_name .. ": " .. tostring(rm_err))
  end
  local readme_state = c.readme_state
  if c.readme_old and c.readme_new ~= c.readme_old then
    local ok, rwerr = mutate.readme_update(c.readme_path, "FEATURES", c.rel, c.readme_row)
    if not ok then
      return back("cannot write " .. c.readme_path .. ": " .. tostring(rwerr))
    end
  elseif not c.readme_old then
    local ok, rwerr =
      mutate.readme_create(c.readme_path, plan.area, "FEATURES", c.rel, c.readme_row)
    if not ok then
      return back("cannot write " .. c.readme_path .. ": " .. tostring(rwerr))
    end
    readme_state = "updated"
  end
  return { id = c.id, from = plan.path, to = c.target, readme = readme_state }, nil
end

---Finish a plan: `status: done`, moved to `Backlog/FEATURES/YYYY-MM-DD_<slug>.md`, a row in the Backlog README. The
---finished copy is created first and the plan file is not removed before it is written; a failing step puts back what
---THIS run changed (never a finished copy another run created: two closes of one plan may overlap, and the later
---one must not delete the earlier one's result). A finished copy a killed run left behind (same text) is resumed.
---A plan whose id is already held by an open task or a finished item is refused (one id namespace).
---`opts.kind = "project"` finishes a project file (`ROADMAP/projects/`) the same way.
---@param id string
---@param opts? { root?: string, date?: string, today?: string, checkpoint_dir?: string, kind?: "plan"|"project" }
---@return { id: string, from: string, to: string, readme: string }|nil result
---@return string|nil err
function M.close(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  -- a project file is finished the same way (`opts.kind = "project"`, see `tasks_nvim.projects.close`), a learning
  -- path too (`"path"`, `tasks_nvim.paths.close`)
  local file_kind = (opts.kind == "project" or opts.kind == "path") and opts.kind or "plan"
  local plan, ferr = finder_of(file_kind)(id, { root = root })
  if not plan then
    local finished = scan.find_done(id, { root = root })
    if finished then
      return { id = id, from = finished.path, to = finished.path, readme = "unchanged" }, nil
    end
    return nil, ferr
  end
  local today = opts.today or model.today()
  local date = opts.date or today
  if not (model.is_date(today) and model.is_date(date)) then
    return nil, "date must be YYYY-MM-DD"
  end
  local old_text, rd_err = fsio.read(plan.path)
  if not old_text then
    return nil, "cannot read " .. plan.path .. ": " .. tostring(rd_err)
  end
  -- `closed_kind` says what the finished file is: in the Backlog a plan or a project reads like a task otherwise
  local new_text, uerr = fm.update_text(old_text, {
    { "status", "done" },
    { "updated", today },
    { "closed_kind", file_kind },
  })
  if not new_text then
    return nil, "cannot update " .. plan.path .. ": " .. tostring(uerr)
  end
  local mutate = require("tasks_nvim.mutate")
  local stem = date .. "_" .. plan.slug
  -- the folder form goes as a folder, with its assets: `Backlog/FEATURES/<date>_<slug>/<date>_<slug>.md`
  local rel = plan.folder and (stem .. "/" .. stem .. ".md") or (stem .. ".md")
  local target = vault.backlog_dir(root, plan.area, "FEATURES") .. "/" .. rel
  -- The finished copy of an earlier, killed close (same text) is picked up; anything else at the target is not ours.
  local resume = false
  if plan.folder then
    local target_dir = fsio.dirname(target)
    if fsio.is_dir(target_dir) or fsio.is_file(target_dir) then
      return nil, "target folder exists: " .. target_dir
    end
  elseif fsio.is_file(target) and fsio.read(target) == new_text then
    resume = true
  elseif fsio.is_file(target) or fsio.is_dir(target) then
    return nil, "target exists: " .. target
  end
  -- One id namespace: the finished plan would read as a finished task of this id.
  local open_task = scan.find(id, { root = root })
  if open_task then
    return nil,
      ("an open task has the id %s (%s): rename it or the plan before finishing the plan"):format(
        id,
        open_task.path
      )
  end
  local held = scan.find_done(id, { root = root })
  if held and fsio.norm(held.path) ~= fsio.norm(target) then
    return nil,
      ("a finished item with the id %s already exists (%s): finishing the plan would make two"):format(
        id,
        held.path
      )
  end
  local readme_path = vault.backlog_readme(root, plan.area)
  local readme_old
  if fsio.is_file(readme_path) then
    local text, r_err = fsio.read(readme_path)
    if not text then
      return nil, "cannot read " .. readme_path .. ": " .. tostring(r_err)
    end
    readme_old = text
  end
  local readme_row = mutate.readme_row("FEATURES", rel, plan, date)
  local readme_new, readme_state = readme_old, "missing"
  if readme_old then
    local changed
    readme_new, changed = mutate.readme_add_row(readme_old, "FEATURES", rel, readme_row)
    readme_state = changed and "updated" or "unchanged"
  end
  if plan.folder then
    return close_folder(plan, {
      id = id,
      old_text = old_text,
      new_text = new_text,
      target = target,
      rel = rel,
      readme_path = readme_path,
      readme_old = readme_old,
      readme_new = readme_new,
      readme_row = readme_row,
      readme_state = readme_state,
    })
  end

  -- Only the finished copy is snapshotted: the README is written LAST and atomically, so a failing step never has a
  -- README of this run to put back (a restore would put the old README over the row another run added).
  local cp, cerr = checkpoint.create({ target }, { dir = opts.checkpoint_dir })
  if not cp then
    return nil, "cannot snapshot before moving: " .. tostring(cerr)
  end
  local created = false
  ---@param msg string
  ---@param extra? string  # More that could not be undone.
  local function fail(msg, extra)
    -- The snapshot noted `target` as "did not exist": a restore would delete a finished copy this run never created.
    -- Nor may it delete the ONLY holder of the plan text: another run that resumed on this run's copy has removed the
    -- plan file, and the copy is all that is left of the plan.
    if not created or (not fsio.is_file(plan.path) and fsio.read(target) == new_text) then
      checkpoint.forget(cp, target)
    end
    local _, restore_errors = checkpoint.restore(cp)
    checkpoint.discard(cp)
    local stuck = { extra }
    for _, e in ipairs(restore_errors) do
      stuck[#stuck + 1] = e.path
    end
    if #stuck > 0 then
      msg = msg .. " (rollback incomplete: " .. table.concat(stuck, ", ") .. ")"
    end
    return nil, msg
  end
  local made, merr = fsio.mkdirp(fsio.dirname(target))
  if not made then
    return fail("cannot create " .. fsio.dirname(target) .. ": " .. tostring(merr))
  end
  if not resume then
    local ok, werr = fsio.create_exclusive(target, new_text)
    if not ok then
      return fail("cannot create " .. target .. ": " .. tostring(werr))
    end
    created = true
  end
  if fsio.read(plan.path) ~= old_text then
    return fail(
      plan.path .. " changed while it was being finished; nothing was changed, run it again"
    )
  end
  local removed, rm_err = fsio.remove(plan.path)
  if not removed and not fsio.is_file(plan.path) and fsio.read(target) == new_text then
    -- an overlapping close removed the plan file first and finished on this copy: carry on to the README
    removed = true
  end
  if not removed then
    return fail("cannot remove " .. plan.path .. ": " .. tostring(rm_err))
  end
  if readme_old and readme_new ~= readme_old then
    -- under the lock and onto the README as it is NOW (another run may have added its row since it was read)
    local wrote, rwerr = mutate.readme_update(readme_path, "FEATURES", rel, readme_row)
    if not wrote then
      -- the plan file is gone and the finished copy is there: put the plan file back before the restore drops it
      local back, b_err = fsio.create_exclusive(plan.path, old_text)
      if not back and not fsio.is_file(plan.path) then
        -- the finished copy is now the only holder of the text: the restore must not delete it
        checkpoint.forget(cp, target)
        return fail(
          "cannot write " .. readme_path .. ": " .. tostring(rwerr),
          ("%s (cannot restore it: %s; the finished copy %s holds the text)"):format(
            plan.path,
            tostring(b_err),
            target
          )
        )
      end
      return fail("cannot write " .. readme_path .. ": " .. tostring(rwerr))
    end
  end
  if not readme_old then
    -- a new area has no Backlog index yet: this finish makes it, with the row
    local wrote, rwerr = mutate.readme_create(readme_path, plan.area, "FEATURES", rel, readme_row)
    if not wrote then
      -- as above: the plan file goes back before the restore drops the finished copy
      local back, b_err = fsio.create_exclusive(plan.path, old_text)
      if not back and not fsio.is_file(plan.path) then
        checkpoint.forget(cp, target)
        return fail(
          "cannot write " .. readme_path .. ": " .. tostring(rwerr),
          ("%s (cannot restore it: %s; the finished copy %s holds the text)"):format(
            plan.path,
            tostring(b_err),
            target
          )
        )
      end
      return fail("cannot write " .. readme_path .. ": " .. tostring(rwerr))
    end
    readme_state = "updated"
  end
  checkpoint.discard(cp)
  return { id = id, from = plan.path, to = target, readme = readme_state }, nil
end

return M
