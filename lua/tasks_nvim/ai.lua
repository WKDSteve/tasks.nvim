---@module 'tasks_nvim.ai'
---@brief Whether tasks.nvim offers its AI functions: the option `ai` and what is found of the ai family.
---@description
--- AI does not push itself forward. `setup({ ai = false })` turns every AI function of tasks.nvim off (no command,
--- no key, no menu entry), `true` turns them on, and `"auto"` (the default) turns them on only where the ai family is
--- found on this machine:
---
--- * ai.nvim: `require("ai")` succeeds and has `setup` (a plugin of another name is not taken for it).
--- * ai-desktop: installed (the manifest `<family>/installed/ai-desktop.json` its installer writes, whose program is
---   there) or running (its `hub.json`, whose process is alive). The same two files as `appkit_core::family`;
---   `<family>` is `$APPKIT_FAMILY_DIR`, else `%LOCALAPPDATA%\appkit-family` (Windows),
---   `~/Library/Application Support/appkit-family` (macOS), `$XDG_DATA_HOME/appkit-family` or
---   `~/.local/share/appkit-family`; the config folder of ai-desktop is `$AI_DESKTOP_CONFIG_DIR`, else
---   `%APPDATA%\ai-desktop`, `~/Library/Application Support/ai-desktop`, `$XDG_CONFIG_HOME/ai-desktop` or
---   `~/.config/ai-desktop`.
---
--- Only files are read (at most 4 KiB each): no network, no secret, nothing is started. Nothing is handed over yet;
--- the hand-over to an agent comes in a later step and asks `enabled()` first.

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

---The config folder of ai-desktop (which holds its `hub.json`), or nil when nothing names one.
---@return string|nil
function M.config_dir()
  local dir = env("AI_DESKTOP_CONFIG_DIR")
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
  return base and vim.fs.joinpath(base, APP) or nil
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

---Whether the process `pid` is alive (signal 0 only asks, it sends nothing).
---@param pid integer
---@return boolean
local function alive(pid)
  local result = vim.uv.kill(pid, 0)
  return result == 0
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
  local config = M.config_dir()
  if config then
    local record = read_json(vim.fs.joinpath(config, "hub.json"))
    local pid = record and record.pid
    if
      record
      and record.app == APP
      and type(pid) == "number"
      and pid > 0
      and pid == math.floor(pid)
      and type(record.port) == "number"
      and record.port > 0
      and alive(pid)
    then
      found.running = true
    end
  end
  return found
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
