-- TESTS/tasks_launcher_spec.lua -- the `tasks` command itself (bin/tasks, bin/tasks.cmd on Windows): docs and rules tell
-- people to type `tasks done ...`, so the command has to exist, print what the engine prints, hand its exit code
-- through and never fail silently (no nvim on the PATH, or a copy of the
-- launcher away from its checkout: a message and exit 3). Starts `sh` / `cmd`: both are in `guard_allow.spawn`
-- of .testing.lua.

return function(H)
  local ok, eq = H.ok, H.eq
  local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))
  local win = vim.fn.has("win32") == 1
  -- resolved here: vim.system looks the program up in the PATH handed to the child, and the bare one has no sh
  local sh = win and "sh" or vim.fn.exepath("sh")

  ---@param path_env string the PATH the launcher sees
  ---@param bin string the folder holding the launcher
  ---@param ... string arguments of `tasks`
  ---@return vim.SystemCompleted
  local function launch(path_env, bin, ...)
    local argv = win and { "cmd.exe", "/d", "/c", bin .. "/tasks.cmd", ... }
      or { sh, bin .. "/tasks", ... }
    return vim.system(argv, { text = true, env = { PATH = path_env } }):wait(60000)
  end

  ---@param r vim.SystemCompleted
  ---@param needle string
  ---@param msg string
  local function says(r, needle, msg)
    ok(
      (r.stderr or ""):find(needle, 1, true) ~= nil,
      msg .. " (stderr: " .. (r.stderr or ""):sub(1, 300) .. ")"
    )
  end

  local bin = repo .. "/bin"
  ok(vim.uv.fs_stat(bin .. "/tasks") ~= nil, "bin/tasks exists")
  ok(vim.uv.fs_stat(bin .. "/tasks.cmd") ~= nil, "bin/tasks.cmd exists")

  -- with nvim on the PATH (the editor running this spec, whatever the PATH of the spec says): the engine runs,
  -- its output and exit code come through (`done` without an id is the usage, exit 2, and writes nothing)
  local sep = win and ";" or ":"
  local nvim_dir = vim.fs.dirname(vim.v.progpath)
  local r = launch(nvim_dir .. sep .. (os.getenv("PATH") or ""), bin, "done")
  eq(r.code, 2, "the exit code of the engine is handed through")
  says(r, "usage", "the engine's usage is printed")

  -- without nvim on the PATH: never silent, exit 3
  local bare
  if win then
    bare = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32"
  else
    -- a PATH with only the one external tool the script needs (`dirname`), so no nvim of the system is found
    bare = vim.fn.tempname()
    vim.fn.mkdir(bare, "p")
    assert(vim.uv.fs_symlink(vim.fn.exepath("dirname"), bare .. "/dirname"))
  end
  local r2 = launch(bare, bin, "done")
  eq(r2.code, 3, "no nvim: exit 3")
  says(r2, "nvim is not on the PATH", "no nvim: it says so")

  -- a copy of the launcher away from its checkout: it cannot find scripts/tasks.lua and says so, exit 3
  local away = vim.fn.tempname() .. "/bin"
  vim.fn.mkdir(away, "p")
  for _, name in ipairs({ "tasks", "tasks.cmd" }) do
    assert(vim.uv.fs_copyfile(bin .. "/" .. name, away .. "/" .. name))
  end
  local r3 = launch(nvim_dir .. sep .. (os.getenv("PATH") or ""), away, "done")
  eq(r3.code, 3, "a launcher without its checkout: exit 3")
  says(r3, "cannot find", "a launcher without its checkout: it says so")
end
