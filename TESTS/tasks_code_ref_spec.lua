-- TESTS/tasks_code_ref_spec.lua -- the code-ref/1 block of a task made from a selection (`tasks_nvim.code_ref`):
-- the Lua port of the reader's check against the goldens of appkit (TESTS/golden/code-ref/, copied from appkit
-- 94a97ff `schemas/code-ref/1/examples/`), the document made from a buffer in a git repository, the block in the file
-- of `:'<,'>Tasks new` (area route and form route), and the private-area question. Nothing leaves the temp folders.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has

  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local code_ref = require("tasks_nvim.code_ref")
  local vault = require("tasks_nvim.vault")
  local mutate = require("tasks_nvim.mutate")
  local config = require("tasks_nvim.config")
  local cmd = require("tasks_nvim.ui.cmd")
  local confirm = require("tasks_nvim.ui.confirm")
  local app = require("tasks_nvim.open_app")

  local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end

  -- ── the goldens of appkit ──────────────────────────────────────────────────
  for _, name in ipairs({ "marking", "function", "minimal" }) do
    eq(
      code_ref.problems(slurp(here .. "/golden/code-ref/" .. name .. ".json")),
      {},
      name .. " golden"
    )
  end
  local body = slurp(here .. "/golden/code-ref/task-body.md")
  local found = code_ref.task_problems(body)
  eq(#found, 2, "the task golden holds two blocks (the json block is no reference)")
  eq(found[1].problems, {}, "block 1")
  eq(found[2].problems, {}, "block 2")

  -- ── what the reader refuses (the traps of the reference) ───────────────────
  local function doc(extra)
    return vim.tbl_extend(
      "force",
      { schema = "code-ref/1", repo = "r", file = "a/b.lua", lines = { 1, 2 } },
      extra or {}
    )
  end
  local function refused(text, part, msg)
    local got = code_ref.problems(type(text) == "string" and text or vim.json.encode(text))
    ok(#got > 0, (msg or part) .. ": refused")
    if part then
      has(table.concat(got, "\n"), part, msg)
    end
  end
  eq(code_ref.problems(vim.json.encode(doc())), {}, "the plain document passes")
  refused(string.rep(" ", 64 * 1024 + 1) .. "{}", "larger than", "size is taken before parsing")
  refused("not json", "not JSON")
  refused("[]", "not a JSON object")
  refused("\255\254", "not JSON in UTF-8", "invalid UTF-8")
  refused(doc({ schema = "code-ref/2" }), "schema", "a higher version")
  refused({ schema = "code-ref/1", repo = "r", file = "a" }, "lines")
  refused(doc({ lines = { true, 2 } }), "lines", "a boolean is no integer")
  refused(doc({ lines = { 3, 2 } }), "1 <= first <= last")
  refused(doc({ lines = { 0, 2 } }), "1 <= first <= last")
  refused(doc({ repo = "../x" }), "repo")
  refused(doc({ repo = "a/b" }), "repo")
  for _, bad in ipairs({
    "/etc/passwd",
    "\\x",
    "C:\\x",
    "C:/x",
    "\\\\host\\x",
    "~/x",
    "$HOME/x",
    "${HOME}/x",
    "%VAR%\\x",
    "a/../b",
    "../a",
    "a\\b",
    "a:12",
    "a//b",
    "./a",
    "a/",
    "a/./b",
  }) do
    refused(doc({ file = bad }), "file", "file " .. bad)
  end
  eq(
    code_ref.problems(vim.json.encode(doc({ file = "a/b..c/d.lua" }))),
    {},
    "a name with two dots is fine"
  )
  refused(doc({ sha = string.rep("A", 40) }), "sha", "an upper-case sha")
  refused(doc({ sha = "abc" }), "sha")
  eq(code_ref.problems(vim.json.encode(doc({ sha = vim.NIL }))), {}, "a null sha is not known")
  refused(doc({ dirty = "yes" }), "dirty")
  refused(doc({ truncated = 1 }), "truncated")
  refused(doc({ class = "secret" }), "class")
  refused(doc({ docmap = { fn = "x" } }), "docmap.node")
  refused(doc({ telemetry = { namespace = "x" } }), "telemetry.key")
  refused(doc({ symbol = string.rep("s", 201) }), "symbol")
  refused(doc({ lang = "Lua" }), "lang")
  refused(doc({ docmap = { node = "../x" } }), "docmap.node leaves")
  -- the excerpt counts in bytes, not characters: 1400 euro signs are 4200 bytes
  refused(
    doc({ excerpt = string.rep("\226\130\172", 1400) }),
    "excerpt is longer",
    "excerpt in bytes"
  )
  eq(
    code_ref.problems(vim.json.encode(doc({ excerpt = string.rep("a", 4096) }))),
    {},
    "4096 bytes pass"
  )
  eq(
    code_ref.problems(vim.json.encode(doc({ excerpt = "/etc/passwd ../x ~/y" }))),
    {},
    "an excerpt is code, never checked as a path"
  )
  refused(doc({ excerpt = "a\0b" }), "control", "NUL in a string")
  refused(doc({ excerpt = "a\194\133b" }), "control", "C1 character")
  refused(doc({ symbol = "a\127" }), "control", "DEL")
  eq(
    code_ref.problems(vim.json.encode(doc({ excerpt = "a\tb\r\nc" }))),
    {},
    "tab and line breaks pass"
  )
  -- a deeply nested document does not overflow the stack
  refused(
    '{"schema":"code-ref/1","repo":"r","file":"a","lines":[1,1],"x":'
      .. string.rep("[", 3000)
      .. string.rep("]", 3000)
      .. "}",
    nil,
    "deep nesting"
  )

  -- the blocks of a task
  local md = table.concat({
    "---",
    "title: x",
    "---",
    "```code-ref",
    vim.json.encode(doc()),
    "```",
    "````md",
    "```code-ref",
    vim.json.encode(doc()),
    "```",
    "````",
    "```code-ref",
    vim.json.encode(doc()),
  }, "\n")
  eq(#code_ref.blocks(md), 1, "a block inside a longer fence is text, an unclosed block is dropped")
  eq(#code_ref.blocks("---\n```code-ref\n{}\n```\n---\n"), 0, "the frontmatter is not body")

  -- ── render: an invalid document never becomes a block ──────────────────────
  local golden = vim.json.decode(slurp(here .. "/golden/code-ref/function.json"))
  local block = code_ref.render(golden)
  ok(block and block:match("^```code%-ref\n") and block:match("\n```$"), "a fenced block")
  eq(#code_ref.task_problems(block), 1)
  eq(
    vim.json.decode(block:match("```code%-ref\n(.-)\n```")),
    golden,
    "the block holds the document"
  )
  local none, why = code_ref.render(vim.tbl_extend("force", golden, { file = "/etc/passwd" }))
  eq(none, nil, "no block for a file that leaves the repository")
  has(table.concat(why, ";"), "leaves the repository")
  eq(
    (code_ref.render(vim.tbl_extend("force", golden, { lines = { 5, 2 } }))),
    nil,
    "no block for bad lines"
  )
  ok(
    not code_ref.strip_excerpt(golden).excerpt and not code_ref.strip_excerpt(golden).truncated,
    "stripped"
  )
  ok(golden.excerpt, "the original keeps its excerpt")

  -- cut on a whole character
  local cut, truncated = code_ref.cut(string.rep("a", 4095) .. "\226\130\172", 4096)
  eq(#cut, 4095, "the euro sign is not cut in two")
  eq(truncated, true)
  eq(select(2, code_ref.cut("abc", 4096)), false)

  -- ── the document of a buffer in a git repository ──────────────────────────
  local function run(args, cwd)
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
    assert(res.code == 0, table.concat(args, " ") .. ": " .. tostring(res.stderr))
    return vim.trim(res.stdout or "")
  end
  local base = H.tmpdir()
  local repo = base .. "/my.repo"
  vim.fn.mkdir(repo .. "/lua", "p")
  run({ "git", "init", "-q" }, repo)
  run({ "git", "config", "user.name", "t" }, repo)
  run({ "git", "config", "user.email", "t@example.invalid" }, repo)
  run({ "git", "config", "commit.gpgsign", "false" }, repo)
  run({ "git", "config", "core.hooksPath", "no-hooks-here" }, repo)
  run({ "git", "config", "core.autocrlf", "false" }, repo)
  local src = repo .. "/lua/a.lua"
  vim.fn.writefile({ "local M = {}", "function M.work(x)", "  return x", "end" }, src)
  run({ "git", "add", "." }, repo)
  run({ "git", "commit", "-q", "-m", "init" }, repo)
  local head = run({ "git", "rev-parse", "HEAD" }, repo)

  vim.cmd("edit " .. vim.fn.fnameescape(src))
  vim.bo.filetype = "lua"
  local buf = vim.api.nvim_get_current_buf()
  local d, reason = code_ref.capture(buf, 2, 4)
  ok(d, tostring(reason))
  eq(d.schema, "code-ref/1")
  eq(d.repo, "my.repo", "the name of the repository, not a path")
  eq(d.file, "lua/a.lua", "repo-relative")
  eq(d.lines, { 2, 4 })
  eq(d.sha, head, "the HEAD")
  eq(d.dirty, false, "a clean file")
  eq(d.lang, "lua")
  eq(d.excerpt, "function M.work(x)\n  return x\nend")
  eq(d.truncated, false)
  eq(code_ref.problems(vim.json.encode(d)), {}, "the document passes the check")
  ok(not vim.json.encode(d):find(base, 1, true), "nothing of this machine in the document")
  has(tostring(d.symbol), "work", "the symbol under the range, where a parser is there")
  -- unsaved changes: dirty
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  return x + 2" })
  eq((code_ref.capture(buf, 2, 4)).dirty, true, "an unsaved buffer is dirty")
  eq(
    (code_ref.capture(buf, 2, 4)).excerpt,
    "function M.work(x)\n  return x + 2\nend",
    "the buffer text"
  )
  vim.cmd("silent write")
  eq((code_ref.capture(buf, 2, 4)).dirty, true, "a saved change not committed is dirty too")
  -- a long range is cut to 4 KiB and says so; the lines stay the whole range
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ string.rep("x", 99) }, 100))
  local long = code_ref.capture(buf, 1, 100)
  eq(#long.excerpt, 4096)
  eq(long.truncated, true)
  eq(long.lines, { 1, 100 }, "lines are the whole range")
  eq(code_ref.problems(vim.json.encode(long)), {}, "the cut document passes")
  -- a carriage return at the end of a line is not part of the excerpt
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a\r", "b\r" })
  eq((code_ref.capture(buf, 1, 2)).excerpt, "a\nb", "no carriage returns in the excerpt")
  vim.bo[buf].modified = false
  vim.cmd("enew!")

  -- a worktree is named after its repository
  local wt = base .. "/wt-folder"
  run({ "git", "worktree", "add", "-q", "-b", "other", wt }, repo)
  eq(code_ref.repo_name(vim.fs.normalize(wt)), "my.repo", "a worktree names its repository")

  -- no file, no repository
  local plain = base .. "/plain.lua"
  vim.fn.writefile({ "x" }, plain)
  vim.cmd("edit " .. vim.fn.fnameescape(plain))
  local nd, nreason = code_ref.capture(vim.api.nvim_get_current_buf(), 1, 1)
  eq(nd, nil)
  has(nreason, "git")
  vim.cmd("enew")
  local sd, sreason = code_ref.capture(vim.api.nvim_get_current_buf(), 1, 1)
  eq(sd, nil, "a buffer without a file has none")
  ok(sreason, "with a reason")

  -- ── into a task file ───────────────────────────────────────────────────────
  local root = F.vault(H)
  vault.set_root(root)
  local o = { root = root, today = F.TODAY, checkpoint_dir = H.tmpdir() .. "/cp" }
  local made = assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Plain" })))
  local blk = assert(code_ref.render(golden))
  assert(code_ref.insert(made.path, blk))
  local text = slurp(made.path)
  local ctx_at = text:find("## Kontext", 1, true)
  local block_at = text:find("```code-ref", 1, true)
  ok(ctx_at and block_at and block_at > ctx_at, "the block stands under ## Kontext")
  ok(not text:find("Warum, woher kam das", 1, true), "the placeholder of the section is replaced")
  eq(#code_ref.blocks(text), 1)
  ok(text:find("## Akzeptanz", 1, true), "the other sections are kept")
  -- an invalid block is never written
  local before_text = slurp(made.path)
  local wrote, werr = code_ref.insert(made.path, '```code-ref\n{ "schema": "code-ref/1" }\n```')
  eq(wrote, false)
  has(tostring(werr), "invalid")
  eq(slurp(made.path), before_text, "the file is untouched")

  -- ── :'<,'>Tasks new ───────────────────────────────────────────────────────
  local before = vim.deepcopy(config.get())
  local saved = {
    yesno = confirm.yesno,
    choose = confirm.choose,
    after_new = app.after_new,
    notify = vim.notify,
  }
  local notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = tostring(msg)
  end
  local seen
  app.after_new = function(id)
    -- the block must be in the file by now
    seen =
      { id = id, text = slurp(vault.root() .. "/" .. id:gsub("/", "/ROADMAP/tasks/") .. ".md") }
  end
  local asked
  local answer = true
  confirm.yesno = function(msg, label, cb)
    asked = { msg = msg, label = label }
    cb(answer)
  end
  local ok2, err2 = pcall(function()
    local function select_task(area_arg, title)
      -- the file as committed, in a fresh buffer
      vim.cmd("enew!")
      run({ "git", "checkout", "--", "lua/a.lua" }, repo)
      vim.cmd("edit! " .. vim.fn.fnameescape(src))
      cmd.task_new({
        args = { area = area_arg },
        kv = {},
        flags = {},
        rest = title and { title } or {},
        range = { range = 1, line1 = 2, line2 = 3 },
      })
    end
    -- the area route
    seen, asked = nil, nil
    config.merge({
      new = { open_after = "never", private_areas = {}, private_vaults = { "nothing" } },
    })
    select_task("lib.nvim", "Area route")
    local created =
      vim.fn.glob(vault.root() .. "/lib.nvim/ROADMAP/tasks/area-route*.md", false, true)
    eq(#created, 1, "the task is made")
    local t = slurp(created[1])
    local bl = code_ref.task_problems(t)
    eq(#bl, 1, "one code-ref block")
    eq(bl[1].problems, {}, "valid")
    local parsed = vim.json.decode(code_ref.blocks(t)[1])
    eq(parsed.repo, "my.repo")
    eq(parsed.file, "lua/a.lua")
    eq(parsed.lines, { 2, 3 })
    eq(parsed.excerpt, "function M.work(x)\n  return x")
    eq(parsed.dirty, false)
    has(t, "refs: [lua/a.lua:2-3]", "the ref of the selection is unchanged")
    eq(asked, nil, "a public area asks nothing")

    -- the block is in the file before the task is offered to an app
    config.merge({ new = { open_after = "ask" } })
    select_task("lib.nvim", "Before the app")
    ok(seen, "after_new ran")
    has(seen.text, "```code-ref", "the block was there when the app was offered the task")

    -- a task without a selection has no block
    cmd.task_new({
      args = { area = "lib.nvim" },
      kv = {},
      flags = {},
      rest = { "No", "selection" },
      range = { range = 0, line1 = 1, line2 = 1 },
    })
    local plain_task =
      vim.fn.glob(vault.root() .. "/lib.nvim/ROADMAP/tasks/no-selection*.md", false, true)
    eq(#plain_task, 1)
    ok(not slurp(plain_task[1]):find("code-ref", 1, true), "no selection, no block")

    -- a private area: the excerpt only after a yes
    config.merge({ new = { open_after = "never", private_areas = { "lib.nvim" } } })
    asked, answer = nil, false
    select_task("lib.nvim", "Private no")
    ok(asked, "a private area asks")
    has(asked.msg, "private")
    local no = vim.fn.glob(vault.root() .. "/lib.nvim/ROADMAP/tasks/private-no*.md", false, true)
    local no_doc = vim.json.decode(code_ref.blocks(slurp(no[1]))[1])
    eq(no_doc.excerpt, nil, "a no writes no excerpt")
    eq(no_doc.lines, { 2, 3 }, "the reference is there")
    asked, answer = nil, true
    select_task("lib.nvim", "Private yes")
    ok(asked, "asked again")
    local yes = vim.fn.glob(vault.root() .. "/lib.nvim/ROADMAP/tasks/private-yes*.md", false, true)
    eq(vim.json.decode(code_ref.blocks(slurp(yes[1]))[1]).excerpt, "function M.work(x)\n  return x")
    -- the whole vault private by its folder name
    config.merge({ new = { private_areas = {}, private_vaults = { "nothing" } } })
    ok(not code_ref.is_private("any", "C:/x/tricentis-vault"), "off when configured away")
    config.merge({ new = { private_areas = {}, private_vaults = { "tricentis-vault" } } })
    ok(code_ref.is_private("any", "C:/x/tricentis-vault"), "a private vault folder")
    ok(not code_ref.is_private("any", "C:/x/tasks-vault"), "another folder is not")

    -- an invalid document is never written: the task stays, a warning says why
    config.merge({ new = { private_areas = {}, private_vaults = { "nothing" } } })
    local orig = code_ref.capture
    code_ref.capture = function(b, f, l)
      local dd = orig(b, f, l)
      dd.file = "/etc/passwd"
      return dd
    end
    notes = {}
    select_task("lib.nvim", "Invalid doc")
    code_ref.capture = orig
    local inv = vim.fn.glob(vault.root() .. "/lib.nvim/ROADMAP/tasks/invalid-doc*.md", false, true)
    eq(#inv, 1, "the task is made")
    ok(not slurp(inv[1]):find("code-ref", 1, true), "but no block")
    ok(table.concat(notes, "\n"):find("leaves the repository", 1, true), "the reason is told")

    -- the form route writes the same block
    local captured
    cmd.form_open = function(spec)
      captured = spec
    end
    select_task(nil, nil)
    cmd.form_open = nil
    assert(captured, "the form opened")
    confirm.choose = function(_, _, cb)
      cb(1)
    end
    captured.on_submit(
      { area = "lib.nvim", opts = { title = "Form route", refs = "lua/a.lua:2-3" } },
      nil
    )
    local ft = vim.fn.glob(vault.root() .. "/lib.nvim/ROADMAP/tasks/form-route*.md", false, true)
    eq(#ft, 1)
    local form_doc = vim.json.decode(code_ref.blocks(slurp(ft[1]))[1])
    eq(form_doc.file, parsed.file, "the form route: the same file")
    eq(form_doc.lines, parsed.lines, "the same lines")
    eq(form_doc.excerpt, parsed.excerpt, "the same excerpt")
    -- a person who cleared the ref line wants no code of it either
    captured = nil
    cmd.form_open = function(spec)
      captured = spec
    end
    select_task(nil, nil)
    cmd.form_open = nil
    captured.on_submit({ area = "lib.nvim", opts = { title = "Form cleared", refs = "" } }, nil)
    local fc = vim.fn.glob(vault.root() .. "/lib.nvim/ROADMAP/tasks/form-cleared*.md", false, true)
    eq(#fc, 1)
    ok(not slurp(fc[1]):find("code-ref", 1, true), "a cleared ref line: no block")
  end)

  confirm.yesno, confirm.choose, app.after_new, vim.notify =
    saved.yesno, saved.choose, saved.after_new, saved.notify
  config.merge(before)
  vault.set_root(nil)
  vim.cmd("enew!")
  if not ok2 then
    error(err2, 0)
  end
end
