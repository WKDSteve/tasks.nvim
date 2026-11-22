---@module 'tasks_nvim.cli_learn'
---@brief The command line of the learning views over all paths: `learn next` (and its siblings), each a document of
---`tasks_nvim.contract_learn` as lines or as JSON.
---@description
---  - `learn next [<area>] [--machine=private|workstation|wsl|env] [--n=N] [--paths=id,id] [--format=tsv|json]`:
---    the next points of the running paths (`tasks.learn_next`); `env` reads `NVIM_MACHINE_ROLE`, no `--machine`
---    means every machine
---  - `learn notes [<text>] [--kind=note|link|image] [--area=a,b] [--paths=id,id] [--done] [--limit=N]
---    [--format=tsv|json]`: the notes, links and images of the points of all paths (`tasks.learn_notes`), `--done`
---    with the finished paths
---  - `learn evidence [<area>] [--competence=<id>] [--paths=id,id] [--done] [--format=tsv|json]`: the evidence of all
---    paths (`tasks.learn_evidence`), `--done` with the finished paths (the portfolio)
---  - `learn history [<area>] [--since=…] [--until=…] [--step=day|week|month] [--paths=id,id] [--format=tsv|json]`: what
---    the series of the learning figures says (`tasks.learn_history`), a line per step
---
--- Read only. `cli.lua` registers it (`register`).

local contract = require("tasks_nvim.contract")
local fsio = require("tasks_nvim.fsio")

local M = {}

M.USAGE_HISTORY =
  "learn history [<area>] [--since=YYYY-MM-DD] [--until=YYYY-MM-DD] [--step=day|week|month] [--paths=id,id] [--format=tsv|json]"

M.USAGE_EVIDENCE =
  "learn evidence [<area>] [--competence=<id>] [--paths=id,id] [--done] [--format=tsv|json]"

M.USAGE_NOTES =
  "learn notes [<text>] [--kind=note|link|image] [--area=a,b] [--paths=id,id] [--done] [--limit=N] [--format=tsv|json]"

M.USAGE =
  "learn next [<area>] [--machine=private|workstation|wsl|env] [--n=N] [--paths=id,id] [--format=tsv|json]"

---@param code string|nil
---@return integer
local function exit_code(code)
  if code == nil then
    return 0
  end
  return code == "invalid_argument" and 2 or 1
end

---Print the document as JSON, or the error; the exit code.
---@param ctx Tasks.CliCtx
---@param doc table|nil
---@param err any
---@return integer
local function emit_json(ctx, doc, err)
  if doc then
    local text, eerr = contract.encode(doc)
    if text then
      ctx.out(text .. "\n")
      return 0
    end
    err = eerr
  end
  local e = type(err) == "table" and err
    or { code = "internal", message = tostring(err), retryable = false }
  ctx.out((contract.encode(contract.error_doc(e, nil)) or "{}") .. "\n")
  return exit_code(e.code)
end

---Say the error of a document that could not be made; the exit code.
---@param ctx Tasks.CliCtx
---@param err any
---@return integer
local function fail(ctx, err)
  local e = type(err) == "table" and err or { message = tostring(err) }
  ctx.warn("error: " .. tostring(e.message))
  return exit_code(e.code)
end

---A list option (`a,b`) as a list; nil when absent.
---@param v any
---@return string[]|nil
local function list_opt(v)
  if v == nil or v == true then
    return nil
  end
  return vim.tbl_filter(function(s)
    return s ~= ""
  end, vim.split(tostring(v), ",", { plain = true, trimempty = true }))
end

---@param ctx Tasks.CliCtx
---@return integer
local function learn_next(ctx)
  local args, opt = ctx.args, ctx.args.opt
  local format = opt.format or "tsv"
  if (format ~= "tsv" and format ~= "json") or #args.pos > 2 then
    ctx.warn("error: usage: " .. M.USAGE)
    return 2
  end
  local machine
  if opt.machine ~= nil then
    local m = tostring(opt.machine)
    machine = require("tasks_nvim.lernbaum").machine_of_role(
      m == "env" and (os.getenv("NVIM_MACHINE_ROLE") or "") or m
    )
    if not machine then
      ctx.warn("error: --machine takes private, workstation, wsl or env, not '" .. m .. "'")
      return 2
    end
  end
  local n
  if opt.n ~= nil then
    n = tonumber(opt.n)
    if not n then
      ctx.warn("error: --n takes a number")
      return 2
    end
  end
  local doc, err = require("tasks_nvim.contract_learn").next({
    area = args.pos[2],
    machine = machine,
    n = n,
    paths = list_opt(opt.paths),
  }, { root = ctx.eo.root, today = ctx.eo.today })
  if format == "json" then
    return emit_json(ctx, doc, err)
  end
  if not doc then
    return fail(ctx, err)
  end
  for _, item in ipairs(doc.items) do
    for _, p in ipairs(item.points) do
      ctx.say(table.concat({
        fsio.clean(item.path),
        p.key and ("#" .. fsio.clean(p.key)) or ("#" .. p.index),
        fsio.clean(p.stage_label),
        fsio.clean(p.label),
        p.safety and "safety" or "-",
      }, "\t"))
    end
  end
  for _, e in ipairs(doc.incomplete) do
    ctx.warn("warn: skipped " .. fsio.clean(e))
  end
  return 0
end

---@param ctx Tasks.CliCtx
---@return integer
local function learn_notes(ctx)
  local args, opt = ctx.args, ctx.args.opt
  local format = opt.format or "tsv"
  if (format ~= "tsv" and format ~= "json") or #args.pos > 2 then
    ctx.warn("error: usage: " .. M.USAGE_NOTES)
    return 2
  end
  local limit
  if opt.limit ~= nil then
    limit = tonumber(opt.limit)
    if not limit then
      ctx.warn("error: --limit takes a number")
      return 2
    end
  end
  local doc, err = require("tasks_nvim.contract_learn").notes({
    query = args.pos[2],
    kind = opt.kind ~= nil and tostring(opt.kind) or nil,
    areas = list_opt(opt.area),
    paths = list_opt(opt.paths),
    include_done = opt.done == true or nil,
    limit = limit,
  }, { root = ctx.eo.root, today = ctx.eo.today })
  if format == "json" then
    return emit_json(ctx, doc, err)
  end
  if not doc then
    return fail(ctx, err)
  end
  for _, it in ipairs(doc.items) do
    ctx.say(table.concat({
      fsio.clean(it.path),
      it.key and ("#" .. fsio.clean(it.key)) or ("#" .. it.index),
      it.state,
      fsio.clean(it.label),
      fsio.clean(it.note or it.link or it.image or ""),
    }, "\t"))
  end
  if doc.truncated then
    ctx.warn(("warn: %d of %d hits shown (--limit)"):format(#doc.items, doc.total))
  end
  for _, e in ipairs(doc.incomplete) do
    ctx.warn("warn: skipped " .. fsio.clean(e))
  end
  return 0
end

---`competences [<area>] [--format=tsv|json]`: the competences of the vault (`tasks.competences`), a line each: id,
---T, P, target in 12 months, target in 24 months, paths, title (`-` for what is not there).
---@param ctx Tasks.CliCtx
---@return integer
local function competences(ctx)
  local args, opt = ctx.args, ctx.args.opt
  local format = opt.format or "tsv"
  if (format ~= "tsv" and format ~= "json") or #args.pos > 1 then
    ctx.warn("error: usage: competences [<area>] [--format=tsv|json]")
    return 2
  end
  local doc, err = require("tasks_nvim.contract_learn").competences(
    { area = args.pos[1] },
    { root = ctx.eo.root, today = ctx.eo.today }
  )
  if format == "json" then
    return emit_json(ctx, doc, err)
  end
  if not doc then
    return fail(ctx, err)
  end
  local function stage(v)
    return v == nil and "-" or ("%g"):format(v)
  end
  local function target(t)
    if not t then
      return "-"
    end
    if t.t == t.p then
      return stage(t.t)
    end
    return ("T%s/P%s"):format(stage(t.t), stage(t.p))
  end
  for _, c in ipairs(doc.items) do
    ctx.say(table.concat({
      fsio.clean(c.id),
      "T " .. stage(c.t),
      "P " .. stage(c.p),
      "12: " .. target(c.target_12),
      "24: " .. target(c.target_24),
      #c.paths > 0 and table.concat(c.paths, ",") or "-",
      fsio.clean(c.title),
    }, "\t"))
    for _, prob in ipairs(c.problems) do
      ctx.warn("warn: " .. fsio.clean(c.id) .. ": " .. fsio.clean(prob))
    end
  end
  for _, e in ipairs(doc.incomplete) do
    ctx.warn("warn: skipped " .. fsio.clean(e))
  end
  return 0
end

---@param ctx Tasks.CliCtx
---@return integer
local function learn_evidence(ctx)
  local args, opt = ctx.args, ctx.args.opt
  local format = opt.format or "tsv"
  if (format ~= "tsv" and format ~= "json") or #args.pos > 2 then
    ctx.warn("error: usage: " .. M.USAGE_EVIDENCE)
    return 2
  end
  local doc, err = require("tasks_nvim.contract_learn").evidence({
    competence = opt.competence ~= nil and tostring(opt.competence) or nil,
    area = args.pos[2],
    paths = list_opt(opt.paths),
    include_done = opt.done == true or nil,
  }, { root = ctx.eo.root, today = ctx.eo.today })
  if format == "json" then
    return emit_json(ctx, doc, err)
  end
  if not doc then
    return fail(ctx, err)
  end
  for _, it in ipairs(doc.items) do
    local f = it["for"]
    ctx.say(table.concat({
      fsio.clean(it.path),
      it.key and ("#" .. fsio.clean(it.key)) or ("#" .. it.index),
      it.state,
      f and (f.axis:upper() .. ("%g"):format(f.level)) or "-",
      fsio.clean(it.label),
      fsio.clean(it.link or ""),
    }, "\t"))
  end
  for _, e in ipairs(doc.incomplete) do
    ctx.warn("warn: skipped " .. fsio.clean(e))
  end
  return 0
end

---@param ctx Tasks.CliCtx
---@return integer
local function learn_history(ctx)
  local args, opt = ctx.args, ctx.args.opt
  local format = opt.format or "tsv"
  if (format ~= "tsv" and format ~= "json") or #args.pos > 2 then
    ctx.warn("error: usage: " .. M.USAGE_HISTORY)
    return 2
  end
  local doc, err = require("tasks_nvim.contract_learn").history({
    area = args.pos[2],
    since = opt.since ~= nil and tostring(opt.since) or nil,
    ["until"] = opt["until"] ~= nil and tostring(opt["until"]) or nil,
    step = opt.step ~= nil and tostring(opt.step) or nil,
    paths = list_opt(opt.paths),
  }, { root = ctx.eo.root, today = ctx.eo.today })
  if format == "json" then
    return emit_json(ctx, doc, err)
  end
  if not doc then
    return fail(ctx, err)
  end
  if not doc.first then
    ctx.say("# no series yet: tasks history record writes it down from today on")
  else
    ctx.say(
      ("# since %s, streak %d (longest %d)"):format(
        doc.first,
        doc.streak.current,
        doc.streak.longest
      )
    )
    ctx.say("# date\tlearned\tseen\tdropped\txp\tdone_h\tdays")
    for _, p in ipairs(doc.points) do
      ctx.say(table.concat({
        p.date,
        tostring(p.learned),
        tostring(p.seen),
        tostring(p.dropped),
        tostring(p.xp),
        ("%g"):format(p.done_h),
        tostring(p.days),
      }, "\t"))
    end
  end
  for _, e in ipairs(doc.incomplete) do
    ctx.warn("warn: skipped " .. fsio.clean(e))
  end
  return 0
end

---The subcommands of `learn`.
local SUBS = {
  next = learn_next,
  notes = learn_notes,
  evidence = learn_evidence,
  history = learn_history,
}

---@param ctx Tasks.CliCtx
---@return integer
local function run(ctx)
  local sub = SUBS[ctx.args.pos[1] or ""]
  if not sub then
    ctx.warn("error: usage: " .. M.USAGE .. "  |  " .. M.USAGE_NOTES .. "  |  " .. M.USAGE_EVIDENCE)
    return 2
  end
  return sub(ctx)
end

---@param commands table<string, fun(ctx: Tasks.CliCtx): integer>
---@param specs table<string, Tasks.CliSpec>
function M.register(commands, specs)
  specs.learn = {
    value = {
      "machine",
      "n",
      "paths",
      "format",
      "kind",
      "area",
      "limit",
      "competence",
      "since",
      "until",
      "step",
    },
    flag = { "done" },
  }
  commands.learn = run
  specs.competences = { value = { "format" }, flag = {} }
  commands.competences = competences
end

return M
