-- TESTS/tasks_file_link_missing_spec.lua -- `plan-link-missing`, `project-link-missing`, `meeting-link-missing`: a dead
-- relative link of a plan, project or meeting file is a warning with its line, as `link-missing` is for a task; a
-- link that resolves, a web link, a link in code and the cover the file names (that is `cover-missing`'s) are quiet.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local check = require("tasks_nvim.check")
  local plans = require("tasks_nvim.plans")
  local meetings = require("tasks_nvim.meetings")

  local root = F.vault(H)
  local opts = { root = root, today = F.TODAY }
  local A = "lib.nvim"
  H.write(root .. "/Literatur/buch.md", "# Buch\n")

  ---@param file string
  ---@return table<string, string[]> code -> messages of the file
  local function codes(file)
    meetings.reset_cache()
    local out = {}
    for _, f in ipairs(check.run(opts).findings) do
      if f.path == file and (f.code:match("link%-missing$") or f.code:match("missing$")) then
        out[f.code] = out[f.code] or {}
        table.insert(out[f.code], f.message)
      end
    end
    return out
  end

  -- three folders below the root: `<root>/<area>/ROADMAP/plans/<slug>.md`
  local quiet =
    "[Buch](../../../Literatur/buch.md) [web](https://x.org/weg) `[c](../code.md)` [h](#teil)\n"
  ---@param path string
  ---@return integer line the dead link is on
  local function add_dead(path)
    local text = H.read(path)
    local line = #vim.split(text, "\n")
    H.write(path, text .. "[tot](../../../Literatur/fehlt.md)\n")
    return line
  end

  for _, kind in ipairs({ "plan", "project" }) do
    local made = assert(
      plans.new(
        A,
        vim.tbl_extend(
          "force",
          opts,
          { title = "Links " .. kind, kind = kind == "project" and "project" or nil }
        )
      )
    )
    -- the cover is named in the frontmatter and linked in the body: `cover-missing`, not a dead link as well
    local text = H.read(made.path):gsub("\n%-%-%-\n", "\ncover: assets/c.png\n---\n", 1)
    H.write(made.path, text .. quiet .. "![Titelbild](assets/c.png)\n")
    eq(codes(made.path), {
      ["cover-missing"] = { "cover assets/c.png is not there" },
    }, kind .. ": links that resolve, web, code, anchor and the cover are no dead link")
    local line = add_dead(made.path)
    eq(codes(made.path)[kind .. "-link-missing"], {
      ("line %d: the link ../../../Literatur/fehlt.md leads to nothing"):format(line),
    }, kind .. ": the dead link with its line")
  end

  -- a meeting in its folder form is three folders below the root as well
  local m = root .. "/lib.nvim/MEETINGS/links/links.md"
  H.write(m, "---\ntitle: Links\nstatus: planned\ndate: 2026-12-01\n---\n\nAgenda.\n" .. quiet)
  eq(codes(m), {}, "meeting: links that resolve are quiet")
  local line = add_dead(m)
  eq(codes(m), {
    ["meeting-link-missing"] = {
      ("line %d: the link ../../../Literatur/fehlt.md leads to nothing"):format(line),
    },
  }, "meeting: the dead link with its line")
  ok(line > 6)
end
