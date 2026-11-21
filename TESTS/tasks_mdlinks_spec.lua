-- TESTS/tasks_mdlinks_spec.lua -- relative Markdown links (`tasks_nvim.mdlinks`): what counts as one, `shift` one folder
-- deeper, and that `folderize` / `attach` keep the links of a path or task pointing at the same file (and a failed
-- `attach` gives back the text it had).

---@diagnostic disable: need-check-nil, param-type-mismatch
-- @scans-data: the spec lists only its own fixture vault in the temp folder

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local mdlinks = require("tasks_nvim.mdlinks")
  local fsio = require("tasks_nvim.fsio")
  local mutate = require("tasks_nvim.mutate")
  local paths = require("tasks_nvim.paths")

  ---@param text string
  ---@return string[]
  local function targets(text)
    local out = {}
    for _, l in ipairs(mdlinks.scan(text)) do
      out[#out + 1] = l.line .. ":" .. l.target
    end
    return out
  end

  -- ── resolve folds `..` by the text: a link from a folder that does not exist yet (a draft's `paths/`) ──
  eq(mdlinks.resolve("/v/a/ROADMAP/paths", "../tasks/x.md"), "/v/a/ROADMAP/tasks/x.md")
  -- the key of two spellings of one file, and of two files that only differ by a climb out of the folder
  ok(mdlinks.key("../assets/a.svg") ~= mdlinks.key("assets/a.svg"), "../x is another file than x")
  eq(mdlinks.key("./assets/a%20b.svg#x"), mdlinks.key("assets/a b.svg"))
  eq(mdlinks.key("assets/../assets/a.svg"), "assets/a.svg")
  eq(mdlinks.key("../../x.md"), "../../x.md")
  eq(mdlinks.key("#only"), nil)
  eq(mdlinks.resolve("E:/v/a/paths", "./../../b%20c.md#k"), "E:/v/b c.md")
  eq(
    mdlinks.resolve("rel/a", "../../../x.md"),
    "../x.md",
    "a relative dir keeps what it cannot fold"
  )
  eq(mdlinks.resolve("/v", "../../x.md"), "/x.md", "never above the root")
  local gone = vim.fn.tempname()
  vim.fn.mkdir(gone .. "/tasks", "p")
  H.write(gone .. "/tasks/x.md", "x\n")
  eq(
    #mdlinks.missing("[x](../tasks/x.md)\n", gone .. "/paths-not-made"),
    0,
    "a link out of a folder that is not there yet still finds its file"
  )
  vim.fn.delete(gone, "rf")

  -- ── what is a link ───────────────────────────────────────────────────────
  local sample = table.concat({
    "---", -- 1
    "title: x [a](fm.md)", -- 2: frontmatter, no link
    "---", -- 3
    "See [Buch](../../Literatur/buch.md) and ![Bild](./img.png).", -- 4
    "Web [w](https://x.org/a) mail [m](mailto:a@b.c) anchor [h](#teil) abs [p](/etc/x)", -- 5
    'Code `[c](../code.md)` stays, [r](<../two words.md> "Title") counts', -- 6
    "```lua", -- 7
    "local s = '[f](../fenced.md)'", -- 8
    "```", -- 9
    "~~~~", -- 10
    "[g](../tilde.md)", -- 11
    "~~~", -- 12: shorter run, the block goes on
    "~~~~", -- 13
    "[ref]: ../ref.md", -- 14
    "[asset](assets/a.png) [w](../wiki_(x).md)", -- 15
  }, "\n")
  eq(targets(sample), {
    "4:../../Literatur/buch.md",
    "4:./img.png",
    "5:https://x.org/a",
    "5:mailto:a@b.c",
    "5:#teil",
    "5:/etc/x",
    "6:../two words.md",
    "14:../ref.md",
    "15:assets/a.png",
    "15:../wiki_(x).md",
  })
  ok(mdlinks.is_relative("../x.md") and mdlinks.is_relative("x.md"))
  for _, t in ipairs({ "", "#a", "/x", "http://x", "https://x", "mailto:a@b", "C:/x", "file:///x" }) do
    ok(not mdlinks.is_relative(t), "not relative: " .. t)
  end

  -- ── shift: one `../` more, nothing else ──────────────────────────────────
  local shifted, n = mdlinks.shift(sample)
  eq(n, 5)
  eq(vim.split(shifted, "\n"), {
    "---",
    "title: x [a](fm.md)",
    "---",
    "See [Buch](../../../Literatur/buch.md) and ![Bild](../img.png).",
    "Web [w](https://x.org/a) mail [m](mailto:a@b.c) anchor [h](#teil) abs [p](/etc/x)",
    'Code `[c](../code.md)` stays, [r](<../../two words.md> "Title") counts',
    "```lua",
    "local s = '[f](../fenced.md)'",
    "```",
    "~~~~",
    "[g](../tilde.md)",
    "~~~",
    "~~~~",
    "[ref]: ../../ref.md",
    "[asset](assets/a.png) [w](../../wiki_(x).md)",
  })
  eq(mdlinks.shift("no links\n"), "no links\n", "a text without links stays")
  eq(mdlinks.scan("text](x.md) and ](y)\n"), {}, "a ]( without a [ before it is no link")
  eq(mdlinks.shift("[a](b.md)\r\nx\r\n"), "[a](../b.md)\r\nx\r\n", "line ends stay")

  -- ── folderize / attach keep a path's links on the same file ─────────────
  local root = F.vault(H)
  local opts = { root = root, today = F.TODAY }
  local A = "lib.nvim"
  local book = root .. "/Literatur/buch.md"
  H.write(book, "# Buch\n")

  local made = assert(paths.new(A, vim.tbl_extend("force", opts, { title = "Mit Buch" })))
  -- `<root>/<area>/ROADMAP/paths/<slug>.md`: three folders up is the root
  local link = "../../../Literatur/buch.md"
  H.write(
    made.path,
    H.read(made.path) .. "\nDas [Buch](" .. link .. ").\n\n```\n[" .. "x](" .. link .. ")\n```\n"
  )
  local function resolves(file, rel)
    local real = vim.uv.fs_realpath(mdlinks.resolve(fsio.dirname(file), rel))
    return real ~= nil and fsio.same_path(real, vim.uv.fs_realpath(book))
  end
  ok(resolves(made.path, link), "the link names the book before")

  local badge = H.tmpdir() .. "/src/badge.png"
  H.write(badge, "png")
  local att = assert(mutate.attach(made.id, badge, opts))
  ok(att.folderized, "the first badge makes the folder form")
  local text = H.read(att.path)
  local moved = "../" .. link
  ok(text:find("[Buch](" .. moved .. ")", 1, true), "the link gained a ../: " .. text)
  ok(resolves(att.path, moved), "and still names the book")
  ok(text:find("```\n[x](" .. link .. ")\n```", 1, true), "the code block is untouched")

  -- ── a task the same way, through folderize ───────────────────────────────
  local t = assert(mutate.new(A, vim.tbl_extend("force", opts, { title = "Mit Link" })))
  H.write(t.path, H.read(t.path) .. "\nSiehe [Buch](../../../Literatur/buch.md).\n")
  local fz = assert(mutate.folderize(t.id, opts))
  ok(fz.changed)
  ok(H.read(fz.path):find("[Buch](../../../../Literatur/buch.md)", 1, true))
  ok(resolves(fz.path, "../../../../Literatur/buch.md"))

  -- ── a failed attach gives back the plain file with its text as it was ────
  local t2 = assert(mutate.new(A, vim.tbl_extend("force", opts, { title = "Zurueck" })))
  H.write(t2.path, H.read(t2.path) .. "\nSiehe [Buch](../../../Literatur/buch.md).\n")
  local before = H.read(t2.path)
  local real_copy = fsio.copy_whole
  fsio.copy_whole = function()
    return false, "stubbed copy failure"
  end
  local res, aerr = mutate.attach(t2.id, badge, opts)
  fsio.copy_whole = real_copy
  ok(res == nil and aerr and aerr:find("stubbed copy failure", 1, true), tostring(aerr))
  ok(H.exists(t2.path), "the plain file is back")
  eq(H.read(t2.path), before, "with the links it had")

  -- ── check: a dead relative link of a path or task is a warning, with its line ──
  local check = require("tasks_nvim.check")
  ---@return table<string, string[]> code -> messages of the file
  local function link_codes(file)
    local out = {}
    for _, f in ipairs(check.run(opts).findings) do
      if f.path == file and (f.code == "link-missing" or f.code == "path-link-missing") then
        out[f.code] = out[f.code] or {}
        table.insert(out[f.code], f.message)
      end
    end
    return out
  end
  -- the links that resolve (the book, after the moves above) are no finding
  eq(link_codes(att.path), {}, "a path whose links all resolve")
  eq(link_codes(fz.path), {}, "a task whose links all resolve")
  eq(link_codes(t2.path), {})

  local path_text = H.read(att.path)
  local dead_line = #vim.split(path_text, "\n") -- the line the appended text starts on (after the last newline)
  H.write(
    att.path,
    path_text
      .. "[tot](../../../../Literatur/fehlt.md) [web](https://x.org/fehlt) [m](mailto:a@b.c) [h](#fehlt)\n"
      .. "`[c](fehlt-im-code.md)` [ok](../../../../Literatur/buch.md#kapitel)\n"
      .. "```\n[f](fehlt-im-block.md)\n```\n"
  )
  eq(link_codes(att.path), {
    ["path-link-missing"] = {
      ("line %d: the link ../../../../Literatur/fehlt.md leads to nothing"):format(dead_line),
    },
  })
  H.write(t2.path, H.read(t2.path) .. "[weg](../weg.md) [bild](assets/fehlt.png)\n")
  local task_hits = link_codes(t2.path)["link-missing"]
  eq(#task_hits, 2, "a plain task: the dead link and its assets/ link (it has no folder)")
  ok(task_hits[1]:find("../weg.md", 1, true) and task_hits[2]:find("assets/fehlt.png", 1, true))
  H.write(fz.path, H.read(fz.path) .. "[bild](assets/fehlt.png)\n")
  eq(link_codes(fz.path), {}, "a folder task's assets/ link is asset-dangling's")

  -- ── one file, two spellings: the image of a point and a link to it are one finding ──
  local spelled =
    assert(paths.new(A, vim.tbl_extend("force", opts, { title = "Zwei Schreibweisen" })))
  local sp = assert(mutate.folderize(spelled.id, opts)).path
  local sdir = vim.fs.dirname(sp)
  H.write(sdir .. "/assets/two words.svg", "<svg/>")
  H.write(
    sp,
    H.read(sp)
      .. "\n## Lernpunkte\n\n"
      .. "- [ ] Weg ![w](assets/gone.svg) {#gone}\n"
      .. "- [ ] Da ![d](assets/two%20words.svg) {#there}\n\n"
      .. "Siehe [weg](./assets/gone.svg), [weg2](assets/go%6Ee.svg) und [da](<./assets/two words.svg>).\n"
  )
  local per_code = {}
  for _, f in ipairs(check.run(opts).findings) do
    if f.path == sp then
      per_code[f.code] = (per_code[f.code] or 0) + 1
    end
  end
  eq(per_code["path-image-missing"], 1, "the image that is not there: " .. vim.inspect(per_code))
  eq(
    per_code["path-link-missing"],
    nil,
    "./ and %-escapes name the image already: " .. vim.inspect(per_code)
  )
end
