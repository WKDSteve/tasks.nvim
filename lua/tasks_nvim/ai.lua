---@module 'tasks_nvim.ai'
---@brief Whether tasks.nvim offers its AI functions: the option `ai` and what is found of the ai family.
---@description
--- AI does not push itself forward. `setup({ ai = false })` turns every AI function of tasks.nvim off (no command,
--- no key, no menu entry), `true` turns them on, and `"auto"` (the default) turns them on only where the ai family is
--- found on this machine:
---
--- * ai.nvim: `require("ai")` succeeds and has `setup` (a plugin of another name is not taken for it).
--- * ai-desktop: installed (the manifest `<family>/installed/ai-desktop.json` its installer writes, whose program is
---   there) or running (its `hub.json`, whose process is alive and, on Windows, not younger than the file). The same
---   two files as `appkit_core::family`; `<family>` is `$APPKIT_FAMILY_DIR`, else `%LOCALAPPDATA%\appkit-family`
---   (Windows), `~/Library/Application Support/appkit-family` (macOS), `$XDG_DATA_HOME/appkit-family` or
---   `~/.local/share/appkit-family`; the config folder of ai-desktop is `$AI_DESKTOP_CONFIG_DIR`, else
---   `%APPDATA%\ai-desktop`, `~/Library/Application Support/ai-desktop`, `$XDG_CONFIG_HOME/ai-desktop` or
---   `~/.config/ai-desktop`.
---
--- Only files are read (at most 4 KiB each) and, on Windows, when the process of `hub.json` started: no network, no
--- secret, nothing is started. The hand-over itself (`:Tasks agent`, `tasks_nvim.agent`) asks `enabled()` first and
--- `hub_record()` for the running ai-desktop.

local M = {}

local APP = "ai-desktop"
local MANIFEST_SCHEMA = "appkit-installed/1"
local MAX_BYTES = 4096

---@param name string
---@return string|nil
local function env(name)
  local value = vim.env[name]
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

---@return string|nil
local function home()
  return env("HOME") or env("USERPROFILE")
end

---The family folder of this machine (where installers register the apps), or nil when nothing names one.
---@return string|nil
function M.family_dir()
  local dir = env("APPKIT_FAMILY_DIR")
  if dir then
    return dir
  end
  local base
  if vim.fn.has("win32") == 1 then
    base = env("LOCALAPPDATA")
  elseif vim.fn.has("mac") == 1 then
    base = home() and vim.fs.joinpath(home(), "Library", "Application Support")
  else
    base = env("XDG_DATA_HOME") or (home() and vim.fs.joinpath(home(), ".local", "share"))
  end
  return base and vim.fs.joinpath(base, "appkit-family") or nil
end

---The config folder of an app of the family (which holds its `hub.json`), or nil when nothing names one.
---@param app string  e.g. "ai-desktop"
---@param prefix string  its variable prefix, e.g. "AI_DESKTOP" (`<prefix>_CONFIG_DIR`)
---@return string|nil
function M.config_dir_of(app, prefix)
  local dir = env(prefix .. "_CONFIG_DIR")
  if dir then
    return dir
  end
  local base
  if vim.fn.has("win32") == 1 then
    base = env("APPDATA")
  elseif vim.fn.has("mac") == 1 then
    base = home() and vim.fs.joinpath(home(), "Library", "Application Support")
  else
    base = env("XDG_CONFIG_HOME") or (home() and vim.fs.joinpath(home(), ".config"))
  end
  return base and vim.fs.joinpath(base, app) or nil
end

---The config folder of ai-desktop (which holds its `hub.json`), or nil when nothing names one.
---@return string|nil
function M.config_dir()
  return M.config_dir_of(APP, "AI_DESKTOP")
end

---A small JSON file as a table; nil when it is missing, too large or not a JSON object.
---@param path string
---@return table|nil
local function read_json(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > MAX_BYTES then
    return nil
  end
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read(MAX_BYTES) or ""
  file:close()
  -- An installer on Windows may write a byte order mark.
  text = text:gsub("^\239\187\191", "")
  local good, doc = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not good or type(doc) ~= "table" then
    return nil
  end
  return doc
end

-- A process that started this much after its `hub.json` was written is another one with the same id (appkit's SLACK).
local SLACK_S = 2
-- Seconds from 1601-01-01 (the start of a FILETIME) to 1970-01-01, and its 100 ns intervals per second.
local EPOCH_S = 11644473600
local TICKS = 10000000
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local kernel_declared = false

---When the process `pid` started, in seconds since 1970: Windows only (`GetProcessTimes` through LuaJIT's ffi, asking
---with the least right), nil wherever it cannot be told.
---@param pid integer
---@return number|nil
function M._started(pid)
  if vim.fn.has("win32") ~= 1 then
    return nil
  end
  local has_ffi, ffi = pcall(require, "ffi")
  if not has_ffi then
    return nil
  end
  if not kernel_declared then
    -- One declaration each: one that another plugin made already stays, and the call below checks it fits.
    pcall(ffi.cdef, "void* OpenProcess(unsigned long access, int inherit, unsigned long pid);")
    pcall(
      ffi.cdef,
      "int GetProcessTimes(void* h, uint64_t* c, uint64_t* e, uint64_t* k, uint64_t* u);"
    )
    pcall(ffi.cdef, "int CloseHandle(void* h);")
    kernel_declared = true
  end
  local good, started = pcall(function()
    local handle = ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
    if handle == nil then
      return nil
    end
    local times = ffi.new("uint64_t[4]")
    local got = ffi.C.GetProcessTimes(handle, times, times + 1, times + 2, times + 3)
    ffi.C.CloseHandle(handle)
    -- 64-bit arithmetic of cdata (no ULL literal: a Neovim on PUC Lua must still load this file).
    local seconds = tonumber(times[0] / ffi.cast("uint64_t", TICKS))
    if got == 0 or seconds <= EPOCH_S then
      return nil
    end
    return seconds - EPOCH_S
  end)
  return good and started or nil
end

---Whether the process `pid` is alive (signal 0 only asks, it sends nothing) and, where the system says when it started,
---not younger than `written` (when its `hub.json` was written): a younger one is another process that got the id of an
---ended ai-desktop (the rule of `appkit_core::family::process_alive`).
---@param pid integer
---@param written number|nil seconds since 1970
---@return boolean
local function alive(pid, written)
  if vim.uv.kill(pid, 0) ~= 0 then
    return false
  end
  local started = written and M._started(pid)
  return not started or started <= written + SLACK_S
end

---ai-desktop on this machine: installed (a manifest whose program is there), running (a `hub.json` of ai-desktop whose
---process is alive).
---@return { installed: boolean, running: boolean }
function M.ai_desktop()
  local found = { installed = false, running = false }
  local family = M.family_dir()
  if family then
    local manifest = read_json(vim.fs.joinpath(family, "installed", APP .. ".json"))
    if
      manifest
      and manifest.schema == MANIFEST_SCHEMA
      and manifest.app == APP
      and type(manifest.program) == "string"
      and manifest.program ~= ""
      and vim.uv.fs_stat(manifest.program) ~= nil
    then
      found.installed = true
    end
  end
  found.running = M.hub_record() ~= nil
  return found
end

---The `hub.json` of a running app of the family: `app`, `port`, `pid`, `instance` (a string, possibly empty), or nil
---when there is none, it is not that app's, its numbers are not whole numbers in range or its process is not alive
---(or, on Windows, started after the file was written: another process with the id of an ended one).
---@param app string
---@param prefix string
---@return { app: string, port: integer, pid: integer, instance: string }|nil
function M.hub_record_of(app, prefix)
  local config = M.config_dir_of(app, prefix)
  if not config then
    return nil
  end
  local path = vim.fs.joinpath(config, "hub.json")
  local record = read_json(path)
  local stat = record and vim.uv.fs_stat(path)
  local written = stat and stat.mtime and (stat.mtime.sec + stat.mtime.nsec / 1e9) or nil
  local pid = record and record.pid
  local port = record and record.port
  if
    record
    and record.app == app
    and type(pid) == "number"
    and pid > 0
    and pid == math.floor(pid)
    and type(port) == "number"
    and port > 0
    and port <= 65535
    and port == math.floor(port)
    and alive(pid, written)
  then
    return {
      app = app,
      port = port,
      pid = pid,
      instance = type(record.instance) == "string" and record.instance or "",
    }
  end
  return nil
end

---The `hub.json` of a running ai-desktop (see `hub_record_of`).
---@return { app: string, port: integer, pid: integer, instance: string }|nil
function M.hub_record()
  return M.hub_record_of(APP, "AI_DESKTOP")
end

---Whether ai.nvim is loaded or can be loaded (`require("ai")` with a `setup`).
---@return boolean
function M.ai_nvim()
  return require("tasks_nvim.soft").check({ "setup" }, pcall(require, "ai")) ~= nil
end

---@class Tasks.AiState
---@field setting boolean|"auto"  The option `ai` as `setup()` left it.
---@field on boolean              Whether the AI functions are offered.
---@field ai_nvim boolean|nil     ai.nvim found (nil: not looked for, the setting decides alone).
---@field ai_desktop { installed: boolean, running: boolean }|nil  ai-desktop found (nil: not looked for).

---What the option says and what is found. With `false` or `true` nothing is looked for (the setting decides alone);
---`look = true` looks anyway (`:checkhealth`).
---@param setting boolean|"auto"|nil  default: the option of `setup()`
---@param look boolean|nil
---@return Tasks.AiState
function M.state(setting, look)
  if setting == nil then
    setting = require("tasks_nvim.config").get().ai
  end
  ---@type Tasks.AiState
  local state = { setting = setting, on = setting == true }
  if setting == "auto" or look then
    state.ai_nvim = M.ai_nvim()
    state.ai_desktop = M.ai_desktop()
    if setting == "auto" then
      state.on = state.ai_nvim or state.ai_desktop.installed or state.ai_desktop.running
    end
  end
  return state
end

---Whether tasks.nvim offers its AI functions now. Each AI function asks this before it shows itself.
---@return boolean
function M.enabled()
  return M.state().on
end

return M
