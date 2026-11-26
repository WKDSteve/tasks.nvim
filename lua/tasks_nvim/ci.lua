---@module 'tasks_nvim.ci'
---@brief The vault gate for CI: rule check, index freshness and a Markdown lint of the generated indexes.
---@description
--- One command a pipeline can run (`tasks ci`, or `scripts/tasks-ci.lua`):
---
---  1. `check`: every rule finding of `tasks.check` (an `error` fails the run;
---     warnings only with `strict`; hints are printed as `info` lines and never fail)
---  2. `index --check`: no `ROADMAP/TASKS.md` is missing, outdated or an orphan
---     (`check` already reports it per area; this step is the explicit,
---     counted form, and it also fails on an index that cannot be rendered)
---  3. `md_lint`: the vault's `TOOLS/scripts/md_lint.lua` over every generated
---     `ROADMAP/TASKS.md` (relative links, anchors, table columns, and -- with
---     lsp.nvim on the runtimepath -- `$VAR/...` links)
---
--- Exit code: 0 all steps passed, 1 something failed. A step that cannot run
--- (no `md_lint.lua`, no Neovim to run it) fails unless `lint = false`: a gate
--- that silently skips a check is not a gate.
---
--- `own_since = <rev>` (`--own-since=<rev>`, the pre-push hook of a shared vault): only findings in the areas that
--- `<rev>...HEAD` changes count. A finding in an area the push does not touch is another session's (a stale index it
--- left on `origin`, an index another engine wrote) and is printed as `foreign:`, never counted. A finding outside the
--- areas counts always, and so does everything when the push changes a file the gate reads for all areas
--- (`tasks-vault.json`, `area-groups.json`, `TOOLS/scripts/md_lint.lua`) or when the diff cannot be read.
---
--- Key responsibilities:
---  - run the steps, collect the lines, print a short summary
---  - `run_lint` is injectable so a spec does not start a child Neovim
---
--- Not its job: writing or fixing anything (`tasks index` regenerates).

local check = require("tasks_nvim.check")
local fsio = require("tasks_nvim.fsio")
local index = require("tasks_nvim.index")
local vault = require("tasks_nvim.vault")

local M = {}

---Files per md_lint call (keeps the command line short on Windows).
M.LINT_CHUNK = 40

---@class Tasks.CiOpts
---@field root? string                # Vault root (default: `vault.root()`).
---@field strict? boolean             # Warnings fail the run too.
---@field lint? boolean               # Run `md_lint` (default true).
---@field md_lint? string             # Path of `md_lint.lua`; an explicit path is trusted (you named it).
---@field trust_vault_lint? boolean    # Allow running `<vault>/TOOLS/scripts/md_lint.lua` (default: `ci.trust_vault_lint` of `setup()`, `$TASKS_TRUST_VAULT_LINT=1`).
---@field nvim? string                # Neovim executable for md_lint (default: the running one).
---@field timeout_ms? integer          # Per md_lint call before it is killed (default `ci.lint_timeout_ms` of `setup()`).
---@field run_lint? fun(files: string[], md_lint: string): integer, string  # Replaces the child process (specs): exit code, output.
---@field own_since? string           # Count only findings in the areas `<rev>...HEAD` changes (see the module head).
---@field changed_paths? fun(root: string, rev: string): string[]|nil, string|nil  # Replaces `git diff` (specs).

---@class Tasks.CiResult
---@field ok boolean
---@field code integer
---@field failed string[]   # Names of the failed steps.
---@field lines string[]    # What was printed.

---Longest a child md_lint may run before it is killed and the step fails: `ci.lint_timeout_ms` of `setup()`.
---@return integer
local function lint_timeout_ms()
  return require("tasks_nvim.config").get().ci.lint_timeout_ms
end

---Turn what `vim.system():wait()` reports into the gate's exit code and output. A child that was
---killed (a signal reads as exit code 0 on POSIX) or that ran into the timeout (`vim.system`
---answers 124 and signal 9, with nothing printed) is a failure with a reason, never a pass.
---@param res { code: integer, signal?: integer, stdout?: string, stderr?: string }
---@param timeout_ms integer
---@return integer code
---@return string output
---@return boolean fatal  the run did not finish on its own: the next chunk would hang or die too
function M.interpret(res, timeout_ms)
  local text = (res.stdout or "") .. (res.stderr or "")
  local signal = res.signal or 0
  if res.code == 124 and signal ~= 0 then
    return 1, ("timed out after %d s and was killed"):format(math.floor(timeout_ms / 1000)), true
  end
  if signal ~= 0 then
    return 1, ("killed by signal %d"):format(signal), true
  end
  return res.code, text, false
end

---@param files string[]
---@param md_lint string
---@param nvim string
---@param timeout_ms integer
---@return integer code
---@return string output
---@return boolean fatal
local function child_lint(files, md_lint, nvim, timeout_ms)
  local cmd = { nvim, "--headless", "-u", "NONE", "-l", md_lint }
  vim.list_extend(cmd, files)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(timeout_ms)
  end)
  if not ok then
    return 1, "cannot start Neovim: " .. tostring(res), true
  end
  return M.interpret(res, timeout_ms)
end

---The command line of the engine, for a fix the gate names (from the vault root).
---@return string
local function engine_command()
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here))))
  return ("nvim --headless -u NONE -l %s/scripts/tasks.lua --vault=."):format(plugin)
end

---Lines that say what to type for the findings a session can fix itself. A gate that only says "stale" is how a stale
---index stays pushed: the session staged its own paths and does not know which file it left behind.
---@param done_in_roadmap string[]  # Ids of tasks with `status: done` still in `ROADMAP/tasks/`.
---@param stale_areas string[]      # Areas whose index is stale.
---@return string[]
function M.fix_lines(done_in_roadmap, stale_areas)
  local lines = {}
  if #done_in_roadmap == 0 and #stale_areas == 0 then
    return lines
  end
  local engine = engine_command()
  lines[1] = "tasks-ci: to fix, from the vault root:"
  for _, id in ipairs(done_in_roadmap) do
    lines[#lines + 1] = ("  %s done %s   # moves it to Backlog/ and rewrites the index"):format(
      engine,
      id
    )
  end
  for _, area in ipairs(stale_areas) do
    lines[#lines + 1] = ("  %s index %s --staged"):format(engine, area)
  end
  lines[#lines + 1] =
    "  stage your task files first, then this, then commit: `--staged` builds the index"
  lines[#lines + 1] =
    "  from the staging area, so another session's uncommitted tasks stay out of it."
  lines[#lines + 1] =
    "  it lists the staged files it counted (`staged`): unstage one that is not yours and run it again."
  return lines
end

---Areas the info line about indexes of another engine names before it only counts the rest.
M.OTHER_ENGINE_SHOWN = 8

---Files the gate reads for every area: a push that changes one of them owns every finding.
M.GLOBAL_FILES = {
  ["tasks-vault.json"] = true,
  ["area-groups.json"] = true,
  ["TOOLS/scripts/md_lint.lua"] = true,
}

---The paths `<rev>...HEAD` changes in the repository of `root`, relative to `root` (renames as a deletion and an
---addition, so the area a task left counts too). Paths outside `root` are left out.
---@param root string
---@param rev string
---@return string[]|nil paths
---@return string|nil err
function M.changed_paths(root, rev)
  local function git(args)
    local ok, res = pcall(function()
      return vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
    end)
    if not ok then
      return nil, tostring(res)
    end
    if res.code ~= 0 then
      return nil, vim.trim(res.stderr or "")
    end
    return res.stdout or ""
  end
  local prefix, perr = git({ "rev-parse", "--show-prefix" })
  if not prefix then
    return nil, "git rev-parse: " .. tostring(perr)
  end
  prefix = vim.trim(prefix)
  local out, derr =
    git({ "diff", "--name-only", "--no-renames", "-z", rev .. "...HEAD", "--", "." })
  if not out then
    return nil, ("git diff %s...HEAD: %s"):format(rev, tostring(derr))
  end
  local paths = {}
  for path in out:gmatch("[^%z]+") do
    if path:sub(1, #prefix) == prefix then
      paths[#paths + 1] = path:sub(#prefix + 1)
    end
  end
  return paths
end

---@class Tasks.CiOwnership
---@field all boolean                    # every finding counts (a global file changed)
---@field areas table<string, boolean>   # the areas the push changes
---@field why? string                    # the global file that made `all` true

---Which areas a push owns.
---@param root string
---@param paths string[]  relative to `root`
---@return Tasks.CiOwnership
function M.ownership(root, paths)
  local own = { all = false, areas = {} }
  for _, path in ipairs(paths) do
    if M.GLOBAL_FILES[path] then
      own.all, own.why = true, path
    end
    local first = path:match("^([^/]+)/")
    if first and vault.has_area(root, first) then
      own.areas[first] = true
    end
  end
  return own
end

---The area of a vault path (absolute or relative to `root`), nil outside the areas.
---@param root string
---@param path string|nil
---@return string|nil
local function area_of(root, path)
  if not path then
    return nil
  end
  local rel = fsio.norm(path)
  if rel:sub(1, #root + 1) == root .. "/" then
    rel = rel:sub(#root + 2)
  end
  local first = rel:match("^([^/]+)/")
  if first and vault.has_area(root, first) then
    return first
  end
  return nil
end

---Run the gate.
---@param opts? Tasks.CiOpts
---@param say? fun(line: string)  # Default: collect only.
---@return Tasks.CiResult
function M.run(opts, say)
  opts = opts or {}
  local result = { ok = true, code = 0, failed = {}, lines = {} }
  ---@param line string
  local function out(line)
    result.lines[#result.lines + 1] = line
    if say then
      say(line)
    end
  end
  ---@param name string
  ---@param why string
  local function fail(name, why)
    result.ok, result.code = false, 1
    result.failed[#result.failed + 1] = name
    out(("tasks-ci: %s FAILED: %s"):format(name, why))
  end

  local root, rerr = vault.root(opts)
  if not root then
    fail("vault", tostring(rerr))
    return result
  end

  -- warnings fail the run when the flag says so or the vault's marker file does (`ci.strict`); `trust_vault_lint` is
  -- never read from the file: code from a synced vault runs only with an explicit trust
  local strict = opts.strict
  if not strict then
    local file = require("tasks_nvim.vault_marker").read(root)
    strict = file ~= nil and file.ci_strict == true
  end

  local done_in_roadmap, stale_areas = {}, {}

  -- 0. which findings are this push's (`own_since`): nil = all of them
  ---@type Tasks.CiOwnership|nil
  local own
  if opts.own_since then
    local paths, perr = (opts.changed_paths or M.changed_paths)(root, opts.own_since)
    if not paths then
      -- a gate that cannot tell whose a finding is counts all of them (never green by not knowing)
      out(
        ("tasks-ci: own-since %s: %s -- every finding counts"):format(
          opts.own_since,
          tostring(perr)
        )
      )
    else
      own = M.ownership(root, paths)
      local names = vim.tbl_keys(own.areas)
      table.sort(names)
      if own.all then
        out(
          ("tasks-ci: own-since %s: %s changed -- every finding counts"):format(
            opts.own_since,
            own.why
          )
        )
        own = nil
      else
        out(
          ("tasks-ci: own-since %s: %d changed path(s), own area(s): %s"):format(
            opts.own_since,
            #paths,
            #names > 0 and table.concat(names, ", ") or "none"
          )
        )
      end
    end
  end
  ---Is a finding at `path` another session's? Never without `own_since`, never outside the areas.
  ---@param path string|nil
  ---@return boolean
  local function foreign(path)
    if not own then
      return false
    end
    local area = area_of(root, path)
    return area ~= nil and not own.areas[area]
  end
  local foreign_count = 0

  -- 1. rule check
  local res, cerr = check.run({ root = root })
  if not res then
    fail("check", tostring(cerr))
  else
    local errors, warnings = res.errors, res.warnings
    for _, f in ipairs(res.findings) do
      if foreign(f.path) then
        foreign_count = foreign_count + 1
        out("foreign: " .. check.format(f, root))
        if f.severity == "warn" then
          warnings = warnings - 1
        else
          errors = errors - 1
        end
      else
        out(check.format(f, root))
        if f.code == "done-in-roadmap" and f.id then
          done_in_roadmap[#done_in_roadmap + 1] = fsio.clean(f.id)
        end
      end
    end
    res = vim.tbl_extend("force", res, { errors = errors, warnings = warnings })
    -- hints (`info`) are shown, never counted: a link into a repository that is not checked out
    -- (`link-repo-absent`) is otherwise invisible in the log of the gate, `--strict` included
    for _, h in ipairs(res.hints or {}) do
      out(check.format(h, root))
    end
    -- many old files share this warning: one line says where they are (all areas, own or foreign)
    local empty_line = check.count_line(res.findings, "empty-template-body")
    if empty_line then
      out("tasks-ci: " .. empty_line)
    end
    local bad = res.errors + (strict and res.warnings or 0)
    local line = ("check: %d error(s), %d warning(s) in %d area(s), %d task file(s) read"):format(
      res.errors,
      res.warnings,
      res.areas,
      res.tasks
    )
    if bad > 0 then
      fail("check", line .. (strict and " (strict: warnings count)" or ""))
    else
      out("tasks-ci: " .. line .. " -- ok")
    end
  end

  -- 2. index freshness, and the list of indexes md_lint gets
  local results, errors = index.write_all({ root = root, check = true })
  local indexes = {}
  if not results then
    fail("index", tostring(errors and errors[1]))
  else
    local stale, skipped, foreign_stale = 0, 0, 0
    local other_engine = {} ---@type string[]
    for _, r in ipairs(results) do
      local theirs = own ~= nil and not own.areas[r.area]
      if r.action == "stale" and theirs then
        foreign_count, foreign_stale = foreign_count + 1, foreign_stale + 1
        out(("foreign: index: %s is %s: %s"):format(r.area, r.reason or "stale", r.path))
      elseif r.action == "stale" then
        stale = stale + 1
        stale_areas[#stale_areas + 1] = fsio.clean(r.area)
        out(
          ("index: %s is %s: %s%s"):format(
            r.area,
            r.reason or "stale",
            r.path,
            r.other_render
                and (" (rendered by another engine: render %d, this one %d)"):format(
                  r.other_render,
                  index.RENDER_VERSION
                )
              or ""
          )
        )
      elseif r.action ~= "removed" and fsio.is_file(vault.index_path(root, r.area)) then
        if theirs then
          -- another session's index: its lint findings are not this push's either
          skipped = skipped + 1
        else
          indexes[#indexes + 1] = vault.index_path(root, r.area)
        end
        if r.other_render then
          other_engine[#other_engine + 1] = ("%s (render %d)"):format(r.area, r.other_render)
        end
      end
    end
    -- one line, not one per area: right after an engine update every index of the vault is another engine's
    if #other_engine > 0 then
      local shown = vim.list_slice(other_engine, 1, M.OTHER_ENGINE_SHOWN)
      out(
        ("info: index: %d index(es) rendered by another engine (this one: render %d), only their summaries may differ, not counted: %s%s"):format(
          #other_engine,
          index.RENDER_VERSION,
          table.concat(shown, ", "),
          #other_engine > #shown and (", … (%d more)"):format(#other_engine - #shown) or ""
        )
      )
    end
    if skipped > 0 then
      out(
        ("tasks-ci: md_lint leaves out %d index(es) of areas this push does not touch"):format(
          skipped
        )
      )
    end
    for _, e in ipairs(errors or {}) do
      out("index: error: " .. tostring(e))
    end
    if stale > 0 or #(errors or {}) > 0 then
      fail(
        "index",
        ("%d stale, %d error(s) in %d area(s)"):format(stale, #(errors or {}), #results)
      )
    else
      out(
        ("tasks-ci: index --check: %d area(s) up to date%s -- ok"):format(
          #results - foreign_stale,
          foreign_stale > 0 and (", %d foreign stale not counted"):format(foreign_stale) or ""
        )
      )
    end
  end

  -- 3. md_lint over the generated indexes
  if opts.lint == false then
    out("tasks-ci: md_lint skipped (lint=false)")
  elseif #indexes == 0 then
    out("tasks-ci: md_lint: no generated index to lint -- ok")
  else
    local md_lint = opts.md_lint or (root .. "/TOOLS/scripts/md_lint.lua")
    -- The default script is code that lives INSIDE the vault and is run with the rights of whoever runs the gate.
    -- A pipeline that checks out a vault from a pull request would run the contributor's Lua. It runs only when
    -- the user said so (`--trust-vault-lint`, `ci.trust_vault_lint`, `$TASKS_TRUST_VAULT_LINT=1`) or named a
    -- script of their own (`--md-lint=<file>`, which is trusted by being named).
    local trusted = opts.md_lint ~= nil
      or opts.run_lint ~= nil
      or opts.trust_vault_lint == true
      or require("tasks_nvim.config").get().ci.trust_vault_lint == true
      or vim.env.TASKS_TRUST_VAULT_LINT == "1"
    if not trusted then
      fail(
        "md_lint",
        ("refusing to run %s from the vault: pass --trust-vault-lint (or set TASKS_TRUST_VAULT_LINT=1 / ci.trust_vault_lint) if you trust it, --md-lint=<your own copy> otherwise, or --no-lint"):format(
          md_lint
        )
      )
    elseif not fsio.is_file(md_lint) then
      fail("md_lint", "script not found: " .. md_lint)
    else
      local runner = opts.run_lint
        or function(files, script)
          return child_lint(
            files,
            script,
            opts.nvim or vim.v.progpath,
            opts.timeout_ms or lint_timeout_ms()
          )
        end
      local bad_chunks, problems, linted = 0, {}, 0
      for i = 1, #indexes, M.LINT_CHUNK do
        local chunk = {}
        for j = i, math.min(i + M.LINT_CHUNK - 1, #indexes) do
          chunk[#chunk + 1] = indexes[j]
        end
        local code, text, fatal = runner(chunk, md_lint)
        linted = linted + #chunk
        if code ~= 0 then
          bad_chunks = bad_chunks + 1
          for line in (text or ""):gmatch("[^\r\n]+") do
            if not line:match("^OK") then
              problems[#problems + 1] = line
            end
          end
        end
        if fatal then
          -- A hung or killed linter: the next chunk would wait out the whole timeout again.
          break
        end
      end
      for _, line in ipairs(problems) do
        out("md_lint: " .. line)
      end
      if bad_chunks > 0 then
        fail(
          "md_lint",
          ("problems in the generated indexes (%d of %d file(s) linted)"):format(linted, #indexes)
        )
      else
        out(("tasks-ci: md_lint: %d index file(s) clean -- ok"):format(#indexes))
      end
    end
  end

  if foreign_count > 0 then
    out(
      ("tasks-ci: %d finding(s) in areas this push does not touch (foreign:): not counted"):format(
        foreign_count
      )
    )
  end
  if result.ok then
    out("tasks-ci: OK")
  else
    for _, line in ipairs(M.fix_lines(done_in_roadmap, stale_areas)) do
      out(line)
    end
    out("tasks-ci: FAILED (" .. table.concat(result.failed, ", ") .. ")")
  end
  return result
end

return M
