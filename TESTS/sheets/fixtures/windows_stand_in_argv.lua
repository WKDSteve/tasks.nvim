-- TESTS/sheets/fixtures/windows_stand_in_argv.lua -- for a sheet with `fakes` on Windows only.
--
-- A `.cmd` stand-in of testing.nvim catches only the bare program name (`powershell`, not `powershell.exe`: testing.nvim
-- task fakes-unter-windows-exe-namen-explorer-exe-rundll32-exe-und), and it runs the parts of an argument after `&` or
-- `|` as commands of their own, `>` and `<` as redirections (task
-- fake-programs-der-windows-stand-in-fuehrt-die-teile-eines-ar): the call is lost, or worse. Until those are fixed, a
-- sheet wraps `vim.system` with this: `.exe` is stripped from the program and those characters become `_` in its
-- arguments, for the programs the sheet names only.
--
-- A sheet loads it with `load(text, "=<name>")`, never `dofile`: a chunk without a file name is runtime to
-- `testing perf`'s trace, so the plugin's own line stays the caller of the start (a `dofile` from `TESTS/` would make
-- every start the sheet's).
local programs = ...
local wanted = {}
for _, name in ipairs(programs) do
  wanted[name] = true
end
local system = vim.system
vim.system = function(cmd, opts, on_exit)
  if type(cmd) == "table" and type(cmd[1]) == "string" then
    local bare = cmd[1]:gsub("%.[eE][xX][eE]$", "")
    if wanted[bare] then
      local copy = { bare }
      for i = 2, #cmd do
        copy[i] = (tostring(cmd[i]):gsub("[&|<>^]", "_"))
      end
      cmd = copy
    end
  end
  return system(cmd, opts, on_exit)
end
