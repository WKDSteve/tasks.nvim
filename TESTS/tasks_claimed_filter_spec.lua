-- TESTS/tasks_claimed_filter_spec.lua -- `--claimed=own|foreign|none`: the filter by the claim of a task (`claims.classes`,
-- `model.filter`, `filter_opts`, the CLI, named lists) and the claim mark and chip of the dashboard.

---@diagnostic disable: need-check-nil

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local claims = require("tasks_nvim.claims")
  local model = require("tasks_nvim.model")
  local filter_opts = require("tasks_nvim.filter_opts")
  local scan = require("tasks_nvim.scan")
  local cli = require("tasks_nvim.cli")
  local core = require("tasks_nvim.ui.dash_core")

  local root = F.vault(H)
  local area = "lib.nvim"
  for _, slug in ipairs({ "mine", "theirs", "expired", "free" }) do
    F.task(H, root, area, slug, F.meta("Task " .. slug, "doing"))
  end
  -- the claim files as `claim` writes them: one of this name, one of somebody else, one that ran out
  local me = claims.default_name()
  local function claim(slug, by, until_)
    H.write(
      ("%s/%s/%s/%s.json"):format(root, claims.DIR, area, slug),
      vim.json.encode({ by = by, since = "2026-01-01T00:00:00Z", ["until"] = until_ })
    )
  end
  claim("mine", me, "2099-01-01T00:00:00Z")
  claim("theirs", "someone@elsewhere", "2099-01-01T00:00:00Z")
  claim("expired", "someone@elsewhere", "2000-01-01T00:00:00Z")

  -- ── classes: own, foreign; an expired claim is none ──
  local classes = claims.classes(root)
  eq(classes[area .. "/mine"], { class = "own", by = me })
  eq(classes[area .. "/theirs"], { class = "foreign", by = "someone@elsewhere" })
  eq(classes[area .. "/expired"], nil, "an expired claim is no claim")
  eq(classes[area .. "/free"], nil)
  eq(
    claims.classes(root, { by = "someone@elsewhere" })[area .. "/theirs"].class,
    "own",
    "own is the name asked with"
  )

  -- ── model.filter ──
  local tasks = assert(scan.all({ root = root }))
  local function ids(f)
    local out = {}
    for _, t in ipairs(model.filter(tasks, f)) do
      out[#out + 1] = t.id
    end
    table.sort(out)
    return out
  end
  local ref = { ref_opts = { root = root } }
  eq(ids(vim.tbl_extend("force", ref, { claimed = { "own" } })), { area .. "/mine" })
  eq(ids(vim.tbl_extend("force", ref, { claimed = { "foreign" } })), { area .. "/theirs" })
  eq(
    ids(vim.tbl_extend("force", ref, { claimed = { "none" } })),
    { area .. "/expired", area .. "/free" },
    "free and expired"
  )
  eq(
    ids(vim.tbl_extend("force", ref, { claimed = { "own", "foreign" } })),
    { area .. "/mine", area .. "/theirs" }
  )
  -- the claims handed in win over the vault's (a caller that read them once)
  eq(
    ids({ claimed = { "own" }, claim_classes = { [area .. "/free"] = { class = "own", by = "x" } } }),
    {
      area .. "/free",
    }
  )

  -- ── filter_opts ──
  local f = assert(filter_opts.parse({ claimed = "own,none" }))
  eq(f.claimed, { "own", "none" })
  local bad, err = filter_opts.parse({ claimed = "mine" })
  eq(bad, nil)
  has(err, "unknown value in --claimed: mine")

  -- ── the CLI ──
  local function run(argv)
    local out, errs = {}, {}
    local code = cli.run(vim.list_extend({ "--vault=" .. root }, argv), {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        errs[#errs + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(errs) }
  end
  local r = run({ "list", "--claimed=foreign", "--format=ids" })
  eq(r.code, 0, r.err)
  eq(vim.trim(r.out), area .. "/theirs")
  r = run({ "list", "--claimed=nobody" })
  eq(r.code, 2, "an unknown value is a usage error: " .. r.out .. r.err)
  has(r.err, "--claimed")
  r = run({ "help" })
  has(r.out, "--claimed=own,foreign,none")

  -- ── named lists keep the field ──
  local lists = require("tasks_nvim.lists")
  local def = lists.from_filter(f, "default")
  eq(def.claimed, "own,none")
  -- saved from the command line, and carried by the contract's document of the lists (`NamedList.options.claimed`)
  vim.fn.delete(lists.path())
  r = run({ "lists", "save", "claimed-by-me", "--claimed=own" })
  eq(r.code, 0, r.err)
  r = run({ "lists", "show", "claimed-by-me" })
  has(r.out, "--claimed=own")
  local doc = vim.json.decode((require("tasks_nvim.api").call("lists", nil, { root = root })))
  local saved
  for _, l in ipairs(doc.lists) do
    if l.name == "claimed-by-me" then
      saved = l
    end
  end
  eq(saved and saved.options.claimed, "own", "the contract carries the field")
  vim.fn.delete(lists.path())

  -- ── the dashboard: the mark of a claimed line, the chip of the filter ──
  eq(core.claim_mark(nil), nil)
  eq(core.claim_mark({ class = "own", by = me }), { "  [claim: mine]", "DiagnosticOk" })
  eq(
    core.claim_mark({ class = "foreign", by = "someone@elsewhere" }),
    { "  [claim: someone@elsewhere]", "DiagnosticWarn" }
  )
  local ready = core.readiness(tasks, root)
  ok(ready and ready.claims, "the readiness carries the claims")
  local w = { area = 8, effort = 2, status = 6 }
  local by_id = {}
  for _, t in ipairs(tasks) do
    by_id[t.id] = t
  end
  has(core.line(by_id[area .. "/mine"], w, ready), "[claim: mine]")
  has(core.line(by_id[area .. "/theirs"], w, ready), "[claim: someone@elsewhere]")
  ok(
    not core.line(by_id[area .. "/expired"], w, ready):find("[claim", 1, true),
    "an expired claim has no mark"
  )
  -- a new claim changes the signature (a claim file is no task file: the dashboard must see it)
  local before = core.signature(tasks, ready)
  claim("free", me, "2099-01-01T00:00:00Z")
  ok(core.signature(tasks, core.readiness(tasks, root)) ~= before, "a claim changes the signature")
  has(table.concat(core.chips({ claimed = { "own" } }), " "), "claimed: own")
end
