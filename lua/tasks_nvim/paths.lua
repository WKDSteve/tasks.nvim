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
local model = require("tasks_nvim.model")
local plans = require("tasks_nvim.plans")
local vault = require("tasks_nvim.vault")
local wikilinks = require("tasks_nvim.wikilinks")

local M = {}

---@type string[]
M.STATUSES = plans.STATUSES

---Read one path file from disk (always returns a file; a broken one carries `errors`; the tree is in `tree`).
---@param path string
---@param ctx { area: string, slug?: string, location?: "roadmap"|"backlog", folder?: boolean, link_resolver?: Tasks.LinkResolver }
---@return Tasks.PlanFile
function M.from_file(path, ctx)
  return plans.from_file(path, vim.tbl_extend("force", { kind = "path" }, ctx))
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
      { area = area, slug = e.slug, folder = e.folder, link_resolver = resolver }
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
---@param id string
---@param opts? table
---@return { id: string, from: string, to: string, readme: string }|nil result
---@return string|nil err
function M.close(id, opts)
  return plans.close(id, vim.tbl_extend("force", opts or {}, { kind = "path" }))
end

---Change one learning point of an open path: its state and reason (`lernbaum.set_state`), under the lock of the file,
---every other byte as it was. `ref` is a key (`syntax`, `#syntax`) or a position (`#3`). `opts.if_match` is the version
---tag the caller read.
---@param id string
---@param ref string|integer
---@param state string
---@param reason? string
---@param opts? { root?: string, today?: string, if_match?: string, dry_run?: boolean }
---@return { id: string, path: string, etag_before: string, etag_after: string, changed: boolean, node: { line: integer, key?: string, state: string }, progress: Tasks.LernProgress }|nil result
---@return string|nil err
---@return table|nil info  # `{ code = "not_found"|"invalid_argument"|"conflict" }`
function M.point(id, ref, state, reason, opts)
  opts = opts or {}
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
    if cur:sub(-#body) ~= body then
      return nil, "cannot place the body of " .. file.path, { code = "invalid_argument" }
    end
    local head = cur:sub(1, #cur - #body)
    local tree = lernbaum.parse(body)
    local node, serr = lernbaum.set_state(tree, ref, state, reason)
    if not node then
      return nil, serr, { code = "invalid_argument" }
    end
    result.node = { line = node.line, key = node.key, state = node.state }
    result.progress = tree.progress
    local text = head .. lernbaum.render(tree)
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

return M
