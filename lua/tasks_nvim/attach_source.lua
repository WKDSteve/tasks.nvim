---@module 'tasks_nvim.attach_source'
---@brief Where `attach` gets its file from when none is named: the clipboard image, the newest screenshot, or an upload.
---@description
--- `attach <id> --clipboard` stores the image on the clipboard, `attach <id> --latest[=<folder>]` the newest
--- image of a screenshot folder that is at most `attach.max_age_s` seconds old (older: the caller is told
--- and asks, nothing is guessed). Both end in `mutate.attach`, so folder-task conversion, the asset name
--- rules and the index stay in one place. The platform access is `lib.nvim` (`clipboard_image`,
--- `fs.latest_file`); the tools are detected, not assumed.
---
--- Without `--name` the asset is called `<slug>-YYYY-MM-DD-HHMM.<ext>`; a name that is taken gets `-2`, `-3`,
--- ... -- an existing asset is never replaced. A name given by the caller is used as it is (taken: an error,
--- as in `mutate.attach`).
---
--- `upload` takes a file the caller put into its own folder for this (`upload_dir`, the hub's): the file is named by
--- the caller's plain file name, and only that folder is looked into. The asset is called `name` (a page's choice, so
--- a name that is taken gets a counter here too). The file stays where it is: the caller takes it away.

local mutate = require("tasks_nvim.mutate")

local M = {}

---@alias Tasks.AttachMode "clipboard"|"latest"|"upload"

---@class Tasks.AttachSourceOpts
---@field root? string
---@field today? string
---@field name? string                       # Asset name; default `<slug>-<date>-<HHMM>.<ext>`.
---@field dir? string                        # `latest`: the folder to look into instead of the configured ones.
---@field dirs? string[]                     # `latest`: the folders (default: `attach.screenshot_dirs`, else the system's).
---@field max_age_s? number                  # `latest`: default `attach.max_age_s`.
---@field index? boolean
---@field now? number                        # Epoch seconds (specs).
---@field clipboard? Lib.ClipboardImage.Opts # Passed to `clipboard_image.save` (specs).
---@field upload_dir? string                 # `upload`: the folder of the caller the file lies in.
---@field upload? string                     # `upload`: the plain name of the file in that folder.
---@field exact? boolean                     # `upload`: the asset is called `name` or nothing is attached (no counter).
---@field kind? string                       # The asset kind (default: `screenshot` for clipboard and latest).
---@field cancelled? fun(): boolean          # `attach_async`: asked before anything is written; true drops the call.

---The folders screenshots usually land in, per system.
---@param os_name? "windows"|"macos"|"linux"
---@param home? string
---@return string[]
function M.suggested_dirs(os_name, home)
  home = home or vim.uv.os_homedir() or "~"
  os_name = os_name
    or (
      require("lib.nvim.cross.platform.is_windows")() and "windows"
      or require("lib.nvim.cross.platform.is_macos")() and "macos"
      or "linux"
    )
  if os_name == "windows" then
    return {
      home .. "/Pictures/Screenshots",
      home .. "/OneDrive/Pictures/Screenshots",
      home .. "/Pictures",
    }
  elseif os_name == "macos" then
    return { home .. "/Desktop", home .. "/Pictures/Screenshots" }
  end
  return { home .. "/Pictures/Screenshots", home .. "/Pictures" }
end

---The folders `latest` looks into.
---@param opts? Tasks.AttachSourceOpts
---@return string[]
function M.screenshot_dirs(opts)
  if opts and opts.dir and opts.dir ~= "" then
    return { opts.dir }
  end
  if opts and opts.dirs and #opts.dirs > 0 then
    return opts.dirs
  end
  local configured = require("tasks_nvim.config").get().attach
  if configured and #configured.screenshot_dirs > 0 then
    return configured.screenshot_dirs
  end
  return M.suggested_dirs()
end

---`<slug>-YYYY-MM-DD-HHMM.<ext>`
---@param id string
---@param ext string
---@param now? number
---@return string
function M.default_name(id, ext, now)
  local slug = id:match("([^/]+)$") or id
  return ("%s-%s.%s"):format(slug, os.date("%Y-%m-%d-%H%M", now), ext)
end

---Is `name` one plain file name: no folder, nothing that climbs out of one?
---@param name any
---@return boolean
function M.plain_upload_name(name)
  return type(name) == "string"
    and name ~= ""
    and name ~= "."
    and name ~= ".."
    and not name:find("[/\\:%z]")
end

---`name` with a counter before the extension: `a.png` -> `a-2.png`.
---@param name string
---@param n integer
---@return string
local function with_counter(name, n)
  local stem, ext = name:match("^(.*)(%.[%w]+)$")
  return ("%s-%d%s"):format(stem or name, n, ext or "")
end

---Copy `src` into the task under its name: the given one, or the default with a counter until one is free.
---@param id string
---@param mode Tasks.AttachMode
---@param src string
---@param ext string
---@param opts Tasks.AttachSourceOpts
---@return table|nil res
---@return string|nil err
local function place(id, mode, src, ext, opts)
  local base = {
    root = opts.root,
    today = opts.today,
    index = opts.index,
    -- The image on the clipboard and the newest image of the screenshot folders are screenshots, wherever the call
    -- comes from (the editor, the command line, a page); a file somebody sent has the kind its sender names, or none.
    kind = opts.kind or (mode ~= "upload" and "screenshot" or nil),
  }
  local res, aerr
  if opts.name and (mode ~= "upload" or opts.exact) then
    res, aerr = mutate.attach(id, src, vim.tbl_extend("force", base, { name = opts.name }))
  else
    local name = opts.name or M.default_name(id, ext, opts.now)
    for n = 1, 50 do
      local try = n == 1 and name or with_counter(name, n)
      res, aerr = mutate.attach(id, src, vim.tbl_extend("force", base, { name = try }))
      if res or not tostring(aerr):find("^asset exists:") then
        break
      end
    end
  end
  return res, aerr
end

---Attach the clipboard image that was saved to `tmp`; the temp file is removed either way.
---@param id string
---@param opts Tasks.AttachSourceOpts
---@param saved boolean
---@param err string|nil
---@param tmp string
---@return table|nil res
---@return string|nil err
local function attach_saved(id, opts, saved, err, tmp)
  if not saved then
    pcall(vim.uv.fs_unlink, tmp)
    return nil, err
  end
  local res, aerr = place(id, "clipboard", tmp, "png", opts)
  pcall(vim.uv.fs_unlink, tmp)
  if res then
    res.source = "clipboard"
  end
  return res, aerr
end

---Attach the clipboard image or the newest screenshot to a task.
---Waits for the clipboard program (on Windows a PowerShell start); the editor uses `attach_async`.
---@param id string                    # `<area>/<slug>`
---@param mode Tasks.AttachMode
---@param opts? Tasks.AttachSourceOpts
---@return table|nil result            # The result of `mutate.attach`, plus `source` (a description of where the file came from).
---@return string|nil err
---@return table|nil too_old           # `latest`: the newest file when it exists but is older than the limit (to ask about).
function M.attach(id, mode, opts)
  opts = opts or {}
  local ext = "png"
  local src, source
  if mode == "clipboard" then
    local tmp = vim.fn.tempname() .. ".png"
    local saved, err = require("lib.nvim.clipboard_image").save(tmp, opts.clipboard)
    return attach_saved(id, opts, saved, err, tmp)
  elseif mode == "latest" then
    local max_age = opts.max_age_s or require("tasks_nvim.config").get().attach.max_age_s
    local found, err, too_old = require("lib.nvim.fs.latest_file").find(
      M.screenshot_dirs(opts),
      { max_age_s = max_age, now = opts.now }
    )
    if not found then
      return nil, err, too_old
    end
    src, source = found.path, found.path
    ext = (found.path:match("%.([%w]+)$") or "png"):lower()
  elseif mode == "upload" then
    if not opts.upload_dir or not M.plain_upload_name(opts.upload) then
      return nil, "attach: no upload was given"
    end
    src, source = opts.upload_dir .. "/" .. opts.upload, "upload"
    if not require("tasks_nvim.fsio").is_file(src) then
      return nil, "attach: the upload is not there"
    end
  else
    return nil, "attach source must be 'clipboard' or 'latest' or 'upload'"
  end

  local res, aerr = place(id, mode, src, ext, opts)
  if res then
    res.source = source
  end
  return res, aerr
end

---The answer of `attach_async` when `opts.cancelled()` said the call is no longer wanted: nothing was attached.
M.CANCELLED = "attach: cancelled"

---`attach` without waiting for the clipboard program: `on_done(res, err, too_old)` gets what `attach` returns.
---`clipboard` asks `lib.nvim.clipboard_image.save_async` (an older lib.nvim without it: `save`, which waits) and
---answers on a later tick; `opts.cancelled()` is asked once the image is there, before anything is written -- true:
---the temp file is removed and the answer is `nil, M.CANCELLED`. The other modes read only folders and answer at once.
---@param id string
---@param mode Tasks.AttachMode
---@param opts? Tasks.AttachSourceOpts
---@param on_done fun(res: table|nil, err: string|nil, too_old: table|nil)
function M.attach_async(id, mode, opts, on_done)
  opts = opts or {}
  if mode ~= "clipboard" then
    on_done(M.attach(id, mode, opts))
    return
  end
  local clip = require("lib.nvim.clipboard_image")
  local tmp = vim.fn.tempname() .. ".png"
  local function saved(ok, err)
    if opts.cancelled and opts.cancelled() then
      pcall(vim.uv.fs_unlink, tmp)
      on_done(nil, M.CANCELLED)
      return
    end
    on_done(attach_saved(id, opts, ok, err, tmp))
  end
  if clip.save_async then
    clip.save_async(tmp, opts.clipboard, saved)
  else
    saved(clip.save(tmp, opts.clipboard))
  end
end

return M
