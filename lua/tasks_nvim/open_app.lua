---@module 'tasks_nvim.open_app'
---@brief `:Tasks open <id> --desktop | --web`: show one task in tasks-desktop or tasks-web.
---@description
--- The page of tasks-desktop shows a task alone when its address is `#task=<id>` (`openRoute` in `ui/app.svelte.ts`,
--- `route.ts`; the id goes through `encodeURIComponent`), the same page as in the bundle of tasks-web. This module
--- builds that address and hands it to the system opener:
---
--- * `--desktop`: `http://127.0.0.1:<port>/#task=<id>`, the port from the `hub.json` of a running tasks-desktop (the
---   discovery of `appkit_core::family`, read by `tasks_nvim.ai.hub_record_of`: files only, no request). The page
---   needs no token in the address: it is the page ai-desktop is opened at the same way (`/#job=<id>`), and the
---   page gets its own session from the hub. Nothing is started: a hub that is not running is told, with `--web`.
--- * `--web`: `file:///<web_dir>/tasks.html#task=<id>` of the tasks-web checkout `setup({ open = { web_dir = } })`
---   names. No search of the disk.
--- * On the Tricentis workstation (`NVIM_MACHINE_ROLE=workstation`) only `--web` (`MASCHINE-04`): the native app is
---   neither looked for nor opened there.
---
--- After `:'<,'>Tasks new` `setup({ new = { open_after = "ask"|"always"|"never" } })` decides whether the new task
--- is shown there too (default `ask`); `after_new` is that step.

local M = {}

---Seam for the system opener (`vim.ui.open`); specs replace it. Called with the address.
---@type (fun(url: string): boolean, string|nil)|nil
M.opener = nil

---Seam for the question "open in tasks-desktop?" (`vim.fn.confirm`); specs replace it. Returns whether the answer is yes.
---@type (fun(prompt: string): boolean)|nil
M.asker = nil

---The task created last by `:Tasks new` in this session (what `open` without an id shows when the buffer is no task).
---@type string|nil
M.last_created = nil

local DESKTOP = "tasks-desktop"
local DESKTOP_PREFIX = "TASKS_DESKTOP"

---Whether this is the Tricentis workstation (the variable of `lua/machine.lua`), case-insensitive.
---@return boolean
function M.workstation()
  return (vim.env.NVIM_MACHINE_ROLE or ""):lower() == "workstation"
end

---The address the page of a task has: `#task=<id>` with the id as `encodeURIComponent` writes it.
---@param id string
---@return string
function M.fragment(id)
  local enc = id:gsub("[^%w%-_%.!~%*'%(%)]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  return "#task=" .. enc
end

---`http://127.0.0.1:<port>/#task=<id>`
---@param port integer
---@param id string
---@return string
function M.desktop_url(port, id)
  return ("http://127.0.0.1:%d/%s"):format(port, M.fragment(id))
end

---`file:///<dir>/tasks.html#task=<id>`; nil when `dir` has no `tasks.html`.
---@param dir string
---@param id string
---@return string|nil url
---@return string|nil err
function M.web_url(dir, id)
  local file = vim.fs.joinpath(vim.fs.normalize(dir), "tasks.html")
  if vim.uv.fs_stat(file) == nil then
    return nil,
      ("no tasks.html in %s (setup({ open = { web_dir = ... } }) names a tasks-web checkout)"):format(
        dir
      )
  end
  local path = file:gsub("[^%w%-_%.~/:]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  -- file:///C:/x on Windows, file:///home/x elsewhere
  local url = "file://" .. (path:sub(1, 1) == "/" and "" or "/") .. path
  return url .. M.fragment(id), nil
end

---The tasks-web checkout of the config, or nil.
---@return string|nil
function M.web_dir()
  local cfg = require("tasks_nvim.config").get().open
  local dir = cfg and cfg.web_dir
  return type(dir) == "string" and dir ~= "" and dir or nil
end

---A running tasks-desktop: its port, or nil with the reason.
---@return integer|nil port
---@return string|nil err
function M.desktop_port()
  if M.workstation() then
    return nil, "tasks-desktop is not used on the workstation (MASCHINE-04): use --web"
  end
  local record = require("tasks_nvim.ai").hub_record_of(DESKTOP, DESKTOP_PREFIX)
  if not record then
    return nil, "tasks-desktop is not running (no hub.json of a live hub): start it, or use --web"
  end
  return record.port, nil
end

---@param url string
---@return boolean ok
---@return string|nil err
local function launch(url)
  if M.opener then
    return M.opener(url)
  end
  local obj, err = vim.ui.open(url)
  if not obj then
    return false, tostring(err)
  end
  return true, nil
end

---Open the task `id` in tasks-desktop (`which = "desktop"`) or tasks-web (`"web"`).
---@param id string
---@param which "desktop"|"web"
---@return boolean ok
---@return string msg  what happened, or why not
function M.open(id, which)
  local url, err
  if which == "desktop" then
    local port
    port, err = M.desktop_port()
    if not port then
      return false, err or "tasks-desktop not found"
    end
    url = M.desktop_url(port, id)
  else
    local dir = M.web_dir()
    if not dir then
      return false,
        "tasks-web is not set up: setup({ open = { web_dir = '<tasks-web checkout>' } })"
    end
    url, err = M.web_url(dir, id)
    if not url then
      return false, err or "tasks-web not found"
    end
  end
  local ok, lerr = launch(url)
  if not ok then
    return false, ("cannot open %s: %s"):format(url, tostring(lerr))
  end
  return true, ("%s -> %s"):format(id, which == "desktop" and "tasks-desktop" or "tasks-web")
end

---Which target `open` uses without a flag: a running tasks-desktop, else a configured tasks-web; nil when neither.
---@return "desktop"|"web"|nil
function M.available()
  if not M.workstation() and M.desktop_port() then
    return "desktop"
  end
  if M.web_dir() then
    return "web"
  end
  return nil
end

---The id of the task a file is: `<root>/<area>/ROADMAP/tasks/<slug>.md` or `.../tasks/<slug>/<slug>.md`.
---@param path string
---@return string|nil
function M.id_of_path(path)
  local p = vim.fs.normalize(path)
  local area, rest = p:match("([^/]+)/ROADMAP/tasks/(.+)%.md$")
  if not area then
    return nil
  end
  local slug = rest:match("^([^/]+)/") or rest
  return area .. "/" .. slug
end

---The task `open` shows when no id is typed: the one of the current buffer, else the one created last.
---@param buf integer|nil
---@return string|nil
function M.default_id(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  return (name ~= "" and M.id_of_path(name)) or M.last_created
end

---After `:'<,'>Tasks new` created `id`: act on `new.open_after` (`ask`, `always`, `never`).
---Nothing is offered when neither tasks-desktop runs nor tasks-web is set up.
---@param id string
---@param notify fun(msg: string, level: "info"|"warn")
function M.after_new(id, notify)
  M.last_created = id
  local mode = (require("tasks_nvim.config").get().new or {}).open_after or "ask"
  if mode == "never" then
    return
  end
  local which = M.available()
  if not which then
    return
  end
  local name = which == "desktop" and "tasks-desktop" or "tasks-web"
  if mode == "ask" then
    local prompt = ("Open %s in %s?"):format(id, name)
    local yes
    if M.asker then
      yes = M.asker(prompt)
    else
      yes = vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
    end
    if not yes then
      return
    end
  end
  local ok, msg = M.open(id, which)
  notify(msg, ok and "info" or "warn")
end

return M
