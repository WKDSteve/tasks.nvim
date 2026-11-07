-- TESTS/tasks_vault_marker_spec.lua -- the marker file tasks-vault.json: the rules of `validate`, what the engine does
-- without the file (as before), with a valid one (its extra areas are areas) and with a refused one (the vault is refused,
-- fail closed, with a message that names the file and the reason).

---@diagnostic disable: need-check-nil

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local marker = require("tasks_nvim.vault_marker")
  local vault = require("tasks_nvim.vault")
  local fsio = require("tasks_nvim.fsio")

  local MIN = '{"schema":1,"plugin":"tasks.nvim","kind":"tasks.vault","layout_version":1}'

  -- ── validate: the rules ────────────────────────────────────────────────────
  local m = assert(marker.validate(MIN))
  eq(m.layout_version, 1)
  eq(m.extra_areas, {})
  eq(m.lang, nil)
  eq(m.ci_strict, nil)

  local full = assert(
    marker.validate(
      '{"schema":1,"plugin":"tasks.nvim","kind":"tasks.vault","layout_version":1,'
        .. '"extra_areas":["ALL","docs"],"lang":"en","ci":{"strict":true}}'
    )
  )
  eq(full.extra_areas, { "ALL", "docs" })
  eq(full.lang, "en")
  eq(full.ci_strict, true)

  local function refused(text, needle, label)
    local got, err = marker.validate(text)
    eq(got, nil, label)
    ok(err:find("^tasks%-vault%.json: "), label .. ": " .. tostring(err))
    has(err, needle, label)
  end
  local function with(extra)
    return '{"schema":1,"plugin":"tasks.nvim","kind":"tasks.vault","layout_version":1,'
      .. extra
      .. "}"
  end
  refused("{ not json", "not valid JSON", "no JSON")
  refused("<<<<<<< HEAD\n" .. MIN .. "\n=======\n>>>>>>> x", "not valid JSON", "a merge conflict")
  refused("[1]", "not a list", "a list")
  refused(with('"colour":"red"'), "unknown key 'colour' (known:", "an unknown key")
  refused(
    with('"ci":{"trust_vault_lint":true}'),
    "unknown key 'ci.trust_vault_lint'",
    "the trust key is never taken"
  )
  refused(
    '{"schema":1,"plugin":"tasks.nvim","kind":"tasks.vault"}',
    "missing key 'layout_version'",
    "no version"
  )
  refused(
    '{"schema":1,"plugin":"obsidian","kind":"tasks.vault","layout_version":1}',
    "belongs to another tool",
    "a foreign plugin"
  )
  refused(
    '{"schema":1,"plugin":"tasks.nvim","kind":"x","layout_version":1}',
    "kind is 'x'",
    "a foreign kind"
  )
  refused(
    '{"schema":2,"plugin":"tasks.nvim","kind":"tasks.vault","layout_version":1}',
    "schema 2 is newer than this engine knows (1): update tasks.nvim",
    "a newer schema"
  )
  refused(
    '{"schema":1,"plugin":"tasks.nvim","kind":"tasks.vault","layout_version":2}',
    "layout_version 2 is newer than this engine knows (1)",
    "a newer layout"
  )
  refused(
    '{"schema":1.5,"plugin":"tasks.nvim","kind":"tasks.vault","layout_version":1}',
    "schema has to be a whole number",
    "a fraction"
  )
  refused(with('"extra_areas":["../x"]'), "'../x' is no folder name", "a path as an area")
  refused(with('"extra_areas":["/etc"]'), "no folder name", "an absolute path")
  refused(with('"extra_areas":["a","a"]'), "listed twice", "a duplicate")
  refused(with('"extra_areas":"ALL"'), "extra_areas has to be a list", "a string")
  refused(with('"lang":"fr"'), "lang 'fr'", "an unknown language")
  refused(with('"ci":{"strict":"yes"}'), "ci.strict has to be true or false", "a string for strict")
  refused(with('"ci":[1]'), "ci has to be an object", "a list for ci")
  refused(MIN .. string.rep(" ", marker.MAX_BYTES), "larger than", "a file over the limit")
  local many = {}
  for i = 1, marker.MAX_AREAS + 1 do
    many[i] = '"a' .. i .. '"'
  end
  refused(with('"extra_areas":[' .. table.concat(many, ",") .. "]"), "more than", "too many areas")

  -- ── without the file: nothing changes ──────────────────────────────────────
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local root = F.vault(H)
  vim.fn.delete(marker.path(root))
  eq(marker.status(root), { present = false })
  eq(select(2, marker.read(root)), nil)
  local plain = vault.area_names(root)
  eq(
    select(1, vault.root({ root = root })),
    vim.fs.normalize(root),
    "a vault without the file is a vault"
  )

  -- ── a valid file: its extra areas are areas, the union keeps the others ────
  vim.fn.mkdir(root .. "/notes", "p")
  ok(not vim.tbl_contains(vault.area_names(root), "notes"), "a bare folder is no area")
  H.write(marker.path(root), with('"extra_areas":["notes","ALL"],"lang":"en"'):gsub("^{", "{"))
  eq(marker.status(root), { present = true, layout_version = 1 })
  ok(vim.tbl_contains(vault.area_names(root), "notes"), "the file names an area")
  local union = vault.extra_areas(root)
  ok(vim.tbl_contains(union, "migrate.nvim"), "setup() extras stay")
  eq(#vim.tbl_filter(function(n)
    return n == "ALL"
  end, union), 1, "a name once")
  for _, name in ipairs(plain) do
    ok(vim.tbl_contains(vault.area_names(root), name), "no area is lost: " .. name)
  end

  -- ── a refused file refuses the vault ───────────────────────────────────────
  H.write(marker.path(root), with('"extras":1'))
  local got, err = vault.root({ root = root })
  eq(got, nil)
  has(err, "tasks-vault.json: unknown key 'extras'", "the message names the file and the key")
  eq(
    select(1, vault.root({ root = root, unchecked = true })),
    vim.fs.normalize(root),
    "hello may ask anyway"
  )
  local status = marker.status(root)
  eq(status.present, true)
  has(status.problem, "unknown key 'extras'")

  -- a file of another tool with the same name does not pass for ours
  H.write(marker.path(root), '{"name":"somebody else"}')
  has(select(2, vault.root({ root = root })), "unknown key 'name'")

  -- a folder with the name is no marker
  vim.fn.delete(marker.path(root))
  vim.fn.mkdir(marker.path(root), "p")
  has(select(2, vault.root({ root = root })), "is not a regular file")
  vim.fn.delete(marker.path(root), "rf")

  -- a link is a way out of the vault
  H.write(root .. "/real.json", MIN)
  local linked = (vim.uv or vim.loop).fs_symlink(root .. "/real.json", marker.path(root))
  if linked then
    ok(fsio.is_link(marker.path(root)))
    has(select(2, vault.root({ root = root })), "is a link")
    vim.fn.delete(marker.path(root))
  end

  -- ── check: a missing file is told once, an old layout too, a valid file is silent ──
  local check = require("tasks_nvim.check")
  local function marker_findings(opts)
    local res = assert(check.run(opts))
    local out = {}
    for _, f in ipairs(res.findings) do
      if f.code:find("^vault%-marker") then
        out[#out + 1] = f
      end
    end
    return out, res
  end
  vim.fn.delete(marker.path(root))
  local missing, res_missing = marker_findings({ root = root })
  eq(#missing, 1)
  eq(missing[1].code, "vault-marker-missing")
  eq(missing[1].severity, "warn", "the vault works without the file")
  eq(missing[1].area, "", "it belongs to no area, like the area-group findings")
  ok(res_missing.warnings >= 1 and res_missing.ok, "a warning, no error")
  eq(
    #marker_findings({ root = root, area = "lib.nvim" }),
    0,
    "a check of one area leaves the vault out"
  )
  H.write(marker.path(root), marker.render({}))
  eq(#marker_findings({ root = root }), 0, "a valid file is silent")
  local saved = marker.LAYOUT_VERSION
  marker.LAYOUT_VERSION = 2
  local old = marker_findings({ root = root })
  marker.LAYOUT_VERSION = saved
  eq(#old, 1)
  eq(old[1].code, "vault-marker-outdated")
  has(old[1].message, "layout version 1, this engine writes 2")

  -- ── the writer ─────────────────────────────────────────────────────────────
  local fresh = H.tmpdir() .. "/fresh"
  vim.fn.mkdir(fresh, "p")
  eq(
    select(1, marker.write(fresh, { extra_areas = { "ALL" }, lang = "de", ci_strict = false })),
    true
  )
  local text = assert(fsio.read(marker.path(fresh)))
  eq(
    text,
    '{\n  "ci": {\n    "strict": false\n  },\n  "extra_areas": [\n    "ALL"\n  ],\n  "kind": "tasks.vault",\n'
      .. '  "lang": "de",\n  "layout_version": 1,\n  "plugin": "tasks.nvim",\n  "schema": 1\n}\n',
    "sorted keys, two spaces, a final newline"
  )
  ok(marker.validate(text), "what the writer makes passes the rules")
  local again, aerr = marker.write(fresh, {})
  eq(again, nil)
  ok(fsio.is_exists(aerr), "never over a file that is there")
  eq(assert(fsio.read(marker.path(fresh))), text, "the file is byte for byte as it was")
  ok(marker.validate(marker.render({})), "the bare file is valid too")
  eq(
    select(1, marker.write(fresh .. "-2", { extra_areas = { "../x" } })),
    nil,
    "a bad area is not written"
  )
end
