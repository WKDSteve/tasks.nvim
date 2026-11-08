@echo off
rem bin/tasks.cmd -- the `tasks` command on Windows (cmd, PowerShell): put this folder on the PATH.
rem
rem   tasks <command> [options]   =   nvim -n -i NONE --headless -u NONE -l scripts/tasks.lua ...
rem
rem Runs in the caller's working directory and hands the exit code through (0 ok, 1 failure, 2 usage). Never silent:
rem a missing nvim or an exit code above 2 (a crash) is named on stderr.
setlocal
rem one-line ifs: a path with ")" (Program Files (x86)) would end a parenthesized block early
set "lua=%~dp0..\scripts\tasks.lua"
if not exist "%lua%" echo tasks: cannot find "%lua%": run bin\tasks.cmd of a tasks.nvim checkout 1>&2& exit /b 3
where nvim >nul 2>nul
if errorlevel 1 (
  echo tasks: nvim is not on the PATH: nothing ran 1>&2
  exit /b 3
)
nvim -n -i NONE --headless -u NONE -l "%lua%" %*
set "rc=%ERRORLEVEL%"
if %rc% GTR 2 echo tasks: nvim ended with exit code %rc% and no verdict ^(crash?^) 1>&2
if %rc% LSS 0 echo tasks: nvim ended with exit code %rc% and no verdict ^(crash?^) 1>&2
exit /b %rc%
