---@module 'tasks_nvim.paths'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Learning paths: one Markdown file per path under `<area>/ROADMAP/paths/`, a tree of learning points.
---@description
--- A learning path organises knowledge, where a plan organises work: it has no stages and no member tasks, but a tree
--- of learning points in `## Lernpunkte` (`tasks_nvim.lernbaum`) and a progress over its leaves. Its file is
--- `<area>/ROADMAP/paths/<slug>.md`, or `paths/<slug>/<slug>.md` once something was attached to it (R14); the id
--- `<area>/<slug>` shares the namespace of the area with tasks, plans, projects and meetings.
---
--- Frontmatter (flat): `title`, `status` (`planning`, `doing`, `parked`, `done`), `areas`, `target`, `links`,
--- `project` (a path may hang in a project; no `phase`), `created`, `updated`. `phase_order`, `gate` and `phase` are a
--- fault (`path-no-stages`). The file is read and written by `tasks_nvim.plans` (`kind = "path"`); a path is finished
--- by hand with `close` like a plan (moved to `Backlog/FEATURES/` with `closed_kind: path`).
---
--- Not its job: promoting a point to a task, the contract documents, the views.

local fm = require("lib.nvim.markdown.frontmatter")
local fsio = require("tasks_nvim.fsio")
local lernbaum = require("tasks_nvim.lernbaum")
local lernlevel = require("tasks_nvim.lernlevel")
local model = require("tasks_nvim.model")
local plans = require("tasks_nvim.plans")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@type string[]
M.STATUSES = plans.STATUSES

---The `xp:` of the tasks the arrows of a tree name (open, else finished; `false` for one without XP or not found).
---@param tree Tasks.LernTree
---@param root string
---@return table<string, integer|false>
function M.task_xp(tree, root)
  local scan = require("tasks_nvim.scan")
  local out = {}
  for _, id in ipairs(lernbaum.promoted_ids(tree)) do
    local t = scan.find(id, { root = root }) or scan.find_done(id, { root = root })
    out[id] = (t and t.xp) or false
  end
  return out
end

---Give a path file the XP of its promoted tasks and evaluate its levels (`level_state`). Without a root (a file read
---on its own) only the points' own XP count.
---@param f Tasks.PlanFile
---@param root? string
---@return Tasks.PlanFile
function M.with_xp(f, root)
  if f.tree and root then
    lernbaum.set_task_xp(f.tree, M.task_xp(f.tree, root))
  end
  if f.tree and f.levels then
    f.level_state = lernlevel.evaluate(f.levels, f.tree)
  end
  return f
end

---Read one path file from disk (always returns a file; a broken one carries `errors`; the tree is in `tree`, the
---levels in `levels` and `level_state`). `ctx.root` gives the promoted points the XP of their tasks.
---@param path string
---@param ctx { area: string, slug?: string, location?: "roadmap"|"backlog", folder?: boolean, link_resolver?: Tasks.LinkResolver, root?: string }
---@return Tasks.PlanFile
function M.from_file(path, ctx)
  local root = ctx.root
  local c = vim.tbl_extend("force", { kind = "path" }, ctx)
  c.root = nil
  return M.with_xp(plans.from_file(path, c), root)
end

---The open paths of an area (`ROADMAP/paths/<slug>.md` and `ROADMAP/paths/<slug>/<slug>.md`), by slug.
---@param area string
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile[]|nil paths
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
  local dir = vault.paths_dir(root, area)
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
      { area = area, slug = e.slug, folder = e.folder, link_resolver = resolver, root = root }
    )
  end
  return out, {}
end

---Every open path of the vault, areas in name order.
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile[]|nil paths
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
    for _, p in ipairs(M.area(a.name, { root = root, link_resolver = resolver }) or {}) do
      out[#out + 1] = p
    end
  end
  return out, nil
end

---An open path by id.
---@param id string
---@param opts? { root?: string, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile|nil path
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
  -- not an area, or one spelled in another case: the same refusal as `plans.find`
  if not vault.has_area(root, area) then
    return nil, "no such open path: " .. id
  end
  local escape = vault.leaves(root, vault.paths_dir(root, area))
  if escape then
    return nil, "no such open path: " .. id
  end
  local path, folder = vault.resolve_plan(root, "path", area, slug)
  if not path then
    return nil, folder --[[@as string]]
  end
  return M.from_file(path, {
    area = area,
    slug = slug,
    folder = folder == true,
    link_resolver = opts.link_resolver or wikilinks.resolver(root),
    root = root,
  }),
    nil
end

---Make a path file (`plans.new` with `kind = "path"`): `opts` as there, without `phases`, `gate` and `phase`.
---@param area string
---@param opts Tasks.NewPlanOpts
---@return { id: string, path: string, slug: string, renamed: boolean }|nil result
---@return string|nil err
---@return table|nil info
function M.new(area, opts)
  return plans.new(area, vim.tbl_extend("force", opts or {}, { kind = "path" }))
end

---Change the frontmatter of an open path (`plans.set` with `kind = "path"`; keys: `plans.SET_KEYS.path`).
---@param id string
---@param patch table<string, any>
---@param opts? table
---@return table|nil result
---@return string|nil err
---@return table|nil info
function M.set(id, patch, opts)
  return plans.set(id, patch, vim.tbl_extend("force", opts or {}, { kind = "path" }))
end

---Finish a path by hand: moved to `Backlog/FEATURES/<date>_<slug>.md` (`closed_kind: path`), a row in the README.
---Starts the routines that waited for the path (`routine_after.settle`: `routines_started`, `notes`).
---@param id string
---@param opts? table
---@return { id: string, from: string, to: string, readme: string, routines_started?: table[], notes?: string[] }|nil result
---@return string|nil err
---@return table|nil info
function M.close(id, opts)
  opts = opts or {}
  local res, err, info = plans.close(id, vim.tbl_extend("force", opts, { kind = "path" }))
  -- the routines that waited for the path (`repeat_after`), now that it is in the Backlog
  if res and not opts.dry_run and res.from ~= res.to then
    local ran, started, notes = pcall(
      require("tasks_nvim.routine_after").settle,
      { root = opts.root, today = opts.today, index = opts.index, ids = { id } }
    )
    if ran then
      res.routines_started, res.notes = started, notes
    end
  end
  return res, err, info
end

---Change the body of an open path under the lock of its file, every byte before the body (the frontmatter) as it was
---and `updated` set when the text changed. `change(body)` gives the new body, or nil with an error and its info.
---@param id string
---@param opts { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@param change fun(body: string, result: table): string|nil, string|nil, table|nil
---@return table|nil result  # `id`, `path`, `etag_before`, `etag_after`, `changed` and what `change` put in it.
---@return string|nil err
---@return table|nil info
local function edit_body(id, opts, change)
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local file, ferr = M.find(id, { root = root })
  if not file then
    return nil, ferr, { code = "not_found" }
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
    if not (parsed and parsed.has_block) then
      return nil, file.path .. " has no readable frontmatter", { code = "invalid_argument" }
    end
    -- the body is the end of the text: what lies before it (the frontmatter) stays byte for byte
    local body = parsed.body or ""
    -- (`sub(-0)` would be the whole text: an empty body is placed at the end)
    if #body > 0 and cur:sub(-#body) ~= body then
      return nil, "cannot place the body of " .. file.path, { code = "invalid_argument" }
    end
    local head = cur:sub(1, #cur - #body)
    local new_body, cerr, cinfo = change(body, result)
    if not new_body then
      return nil, cerr, cinfo
    end
    local text = head .. new_body
    if text ~= cur then
      text = fm.update_text(text, { { "updated", today } }) or text
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

---Write the schedule of an open path (`## Zeitplan`, `tasks_nvim.path_schedule`) from its tree: the points with
---`{h=…}`, under the lock of the file, every other byte as it was. Refused for a path without hours or without the
---section (`invalid_argument`).
---@param id string
---@param opts? { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return { id: string, path: string, etag_before: string, etag_after: string, changed: boolean, rows: integer }|nil result
---@return string|nil err
---@return table|nil info
function M.write_schedule(id, opts)
  local sched = require("tasks_nvim.path_schedule")
  return edit_body(id, opts or {}, function(body, result)
    local rows = sched.rows(lernbaum.parse(body))
    local lines = sched.render(rows)
    if not lines then
      return nil,
        "no point carries {h=…}: nothing to put in ## Zeitplan",
        { code = "invalid_argument" }
    end
    result.rows = #rows
    local new, perr = sched.place(body, lines)
    if not new then
      return nil, perr, { code = "invalid_argument" }
    end
    return new
  end)
end

---Change one learning point of an open path: its state and reason (`lernbaum.set_state`), its XP (`opts.xp`,
---`lernbaum.set_xp`; `""` removes it) and/or its note (`opts.note`, `lernbaum.set_note`; an empty text removes it),
---under the lock of the file, every other byte as it was. `ref` is a key (`syntax`, `#syntax`) or a position (`#3`).
---`state` may be nil when a note or XP is given. `opts.if_match` is the version tag the caller read.
---@param id string
---@param ref string|integer
---@param state? string
---@param reason? string
---@param opts? { root?: string, today?: string, if_match?: string, dry_run?: boolean, note?: string, xp?: integer|string }
---A changed state starts the routines that waited for a point of the path (`routines_started`, `notes`).
---@return { id: string, path: string, etag_before: string, etag_after: string, changed: boolean, node: { line: integer, key?: string, state: string, xp?: integer }, progress: Tasks.LernProgress, routines_started?: table[], notes?: string[] }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict" }`
function M.point(id, ref, state, reason, opts)
  opts = opts or {}
  local res, err, info = edit_body(id, opts, function(body, result)
    local tree = lernbaum.parse(body)
    if state == nil and opts.note == nil and opts.xp == nil then
      return nil, "nothing to change: give a state, a note or xp", { code = "invalid_argument" }
    end
    local node, serr
    if state ~= nil then
      node, serr = lernbaum.set_state(tree, ref, state, reason)
      if not node then
        return nil, serr, { code = "invalid_argument" }
      end
    end
    if opts.xp ~= nil then
      node, serr = lernbaum.set_xp(tree, ref, opts.xp)
      if not node then
        return nil, serr, { code = "invalid_argument" }
      end
    end
    if opts.note ~= nil then
      node, serr = lernbaum.set_note(tree, ref, opts.note)
      if not node then
        return nil, serr, { code = "invalid_argument" }
      end
    end
    result.node = { line = node.line, key = node.key, state = node.state, xp = node.xp_own }
    result.progress = tree.progress
    return lernbaum.render(tree)
  end)
  -- a point (or the stage above it) may be what a routine waits for (`repeat_after: <path>#<key>`)
  if res and res.changed and state ~= nil and not opts.dry_run then
    local ran, started, notes = pcall(
      require("tasks_nvim.routine_after").settle,
      { root = opts.root, today = opts.today, index = opts.index, ids = { res.id } }
    )
    if ran then
      res.routines_started, res.notes = started, notes
    end
  end
  return res, err, info
end

---Mark the reward of a level granted (`given = true`, `[x]` in `## Level`) or not, under the lock of the file, every
---other byte as it was. `ref` is the level number (`1`, `"2"`) or `"done"` for the line of the whole path; a level
---without a reward is refused.
---@param id string
---@param ref string|integer
---@param given boolean
---@param opts? { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return { id: string, path: string, etag_before: string, etag_after: string, changed: boolean, level: { ref: string, line: integer, given: boolean, before: boolean } }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict" }`
function M.set_reward(id, ref, given, opts)
  opts = opts or {}
  if type(given) ~= "boolean" then
    return nil, "given must be true or false", { code = "invalid_argument" }
  end
  return edit_body(id, opts, function(body, result)
    local lv = lernlevel.parse(body)
    local before
    for _, l in ipairs(vim.list_extend(vim.list_slice(lv.levels, 1), { lv.final })) do
      if l.ref == tostring(ref) then
        before = l.given
      end
    end
    local out, err = lernlevel.set_reward(lv, ref, given)
    if not out then
      return nil, err, { code = "invalid_argument" }
    end
    local line
    for _, l in ipairs(vim.list_extend(vim.list_slice(lv.levels, 1), { lv.final })) do
      if l.ref == tostring(ref) then
        line = l.line
      end
    end
    result.level = { ref = tostring(ref), line = line, given = given, before = before == true }
    return out
  end)
end

---Write the `## Level` section of an open path from a spec (`lernlevel.write`): its levels with threshold, name, badge
---and reward, and the line for the whole path; an empty spec removes them. `result.before` is the spec the section
---had (`lernlevel.spec_of`; nil when it held lines a spec cannot carry).
---@param id string
---@param spec Tasks.LevelsSpec
---@param opts? { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return table|nil result
---@return string|nil err
---@return table|nil info
function M.set_levels(id, spec, opts)
  return edit_body(id, opts or {}, function(body, result)
    result.before = lernlevel.spec_of(lernlevel.parse(body))
    -- the words of the lines: the section's own, else the language the vault's marker file names
    local root = (opts or {}).root or require("tasks_nvim.vault").root(opts or {})
    local marker = root and require("tasks_nvim.vault_marker").read(root)
    local out, err = lernlevel.write(body, spec, { lang = marker and marker.lang or nil })
    if not out then
      return nil, err, { code = "invalid_argument" }
    end
    return out
  end)
end

return M
