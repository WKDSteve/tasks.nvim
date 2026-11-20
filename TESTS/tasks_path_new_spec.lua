-- TESTS/tasks_path_new_spec.lua -- making a learning path from the command line (`tasks path-new`) and the editor
-- (`:Tasks path-new`): the file under ROADMAP/paths with its sections, the options handed to `paths.new`, the learning
-- template, a taken slug, the usage errors, and the new path opened in the editor.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local lernbaum = require("tasks_nvim.lernbaum")
  local paths = require("tasks_nvim.paths")
  local vault = require("tasks_nvim.vault")

  local TODAY = "2026-11-20"
  local root = F.vault(H)
  local A = "lib.nvim"

  ---@param argv string[]
  ---@return integer code
  ---@return string out
  ---@return string err
  local function run(argv)
    local out, err = {}, {}
    vim.list_extend(argv, { "--vault=" .. root, "--today=" .. TODAY })
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end

  -- ── the command line ──────────────────────────────────────────────────────
  local code, out, err = run({
    "path-new",
    A,
    "Lua lernen",
    "--areas=lib.nvim,nvim-config",
    "--status=doing",
    "--summary=Plugins selbst schreiben.",
    "--links=https://www.lua.org/manual/5.4/",
    "--icon=📘",
  })
  eq(code, 0, err)
  has(out, "created\t" .. A .. "/lua-lernen\t")
  local file = root .. "/" .. A .. "/ROADMAP/paths/lua-lernen.md"
  local text = assert(H.read(file), "the path is under ROADMAP/paths")
  has(text, "title: Lua lernen\n")
  has(text, "status: doing\n")
  has(text, "areas: [lib.nvim, nvim-config]\n")
  has(text, "links: [https://www.lua.org/manual/5.4/]\n")
  has(text, "icon: 📘\n")
  has(text, "Plugins selbst schreiben.")
  has(text, "## Lernpunkte")
  lacks(text, "phase_order", "a path has no stages")
  local found = assert(paths.find(A .. "/lua-lernen", { root = root }))
  eq(found.status, "doing")
  ok(lernbaum.parse(text:match("\n%-%-%-\n(.*)$") or "").has_section, "the tree's section is there")

  -- the learning template: the sections of a learning path (concept §5)
  local _
  code, _, err = run({ "path-new", A, "Rust lernen", "--template=learning" })
  eq(code, 0, err)
  local rust = assert(H.read(root .. "/" .. A .. "/ROADMAP/paths/rust-lernen.md"))
  has(rust, "## Ziel und Kompetenzstufe")
  has(rust, "## Selbstcheck")
  has(rust, "## Lernpunkte")
  lacks(rust, "phase_order")

  -- a taken slug gets -2; the title may come as --title
  code, out, err = run({ "path-new", A, "--title=Lua lernen" })
  eq(code, 0, err)
  has(out, "created\t" .. A .. "/lua-lernen-2\t")

  -- what is wrong is said, with the usage
  code, _, err = run({ "path-new", A })
  eq(code, 2)
  has(err, "usage: path-new <area>")
  code = run({ "path-new", A, "X", "--phases=a,b" })
  eq(code, 2, "a path has no stages: --phases is no option of path-new")
  code, _, err = run({ "path-new", A, "Bad", "--template=nope" })
  eq(code, 1)
  has(err, "unknown template")

  -- ── the editor ────────────────────────────────────────────────────────────
  vault.set_root(root)
  local told = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    told[#told + 1] = tostring(msg)
  end
  local cmd = require("tasks_nvim.ui.cmd")
  cmd.path_new({
    args = { area = A },
    rest = { "Go", "lernen" },
    flags = { status = "doing" },
    kv = {},
  })
  local go = root .. "/" .. A .. "/ROADMAP/paths/go-lernen.md"
  has(assert(H.read(go)), "status: doing\n")
  ok(
    vim.api.nvim_buf_get_name(0):gsub("\\", "/"):find("ROADMAP/paths/go-lernen.md", 1, true) ~= nil,
    "the new path is opened: " .. vim.api.nvim_buf_get_name(0)
  )
  has(table.concat(told, "\n"), "created learning path " .. A .. "/go-lernen")
  cmd.path_new({ args = { area = A }, rest = {}, flags = { title = "Zig lernen" }, kv = {} })
  ok(H.read(root .. "/" .. A .. "/ROADMAP/paths/zig-lernen.md") ~= nil, "--title names it")
  told = {}
  cmd.path_new({ args = { area = A }, rest = {}, flags = {}, kv = {} })
  has(table.concat(told, "\n"), "a learning path needs a title")

  vim.notify = real_notify
  vault.set_root(nil)
  vim.cmd("silent! %bwipeout!")
end
