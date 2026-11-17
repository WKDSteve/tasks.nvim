---@module 'tasks_nvim.agent'
---@brief Hands a task to an agent: ai-desktop's job intake (`POST /jobs`), the way tasks-desktop's button does.
---@description
--- `:Tasks agent [<id>] [mode=prefill|run] [kind=...]` (`tasks_nvim.ui.cmd`) asks this module. The hand-over to
--- ai-desktop is a request between two programs of the person on this machine (ai-desktop's `docs/JOBS.md`):
---
--- 1. `hub.json` of a running ai-desktop (`tasks_nvim.ai.hub_record`): its port, pid and instance; files only.
--- 2. `GET /health` on that port: it must answer as ai-desktop with the instance of `hub.json`, so the secret never goes
---    to another program that took the port.
--- 3. `control.secret` beside `hub.json`, 64 hex digits, read now (it changes with every start of ai-desktop), sent in
---    the `Authorization` header and nowhere else: never logged, never in a message, never on a command line (the
---    request goes through `vim.uv` TCP, no curl).
--- 4. On Windows, `AllowSetForegroundWindow(<pid>)` (LuaJIT FFI), so ai-desktop may bring its window to the front.
--- 5. `POST /jobs` with `{ source, task_id, title, markdown, vault, area, mode, kind }`.
---
--- No `private` is sent: the vault has no class of its areas; ai-desktop's own `private_areas` decides and asks before
--- a private area goes to a model that is not local. Low-level: no notification here, every function returns its
--- error (`tasks_nvim.ui.cmd` says it).

local M = {}

M.SOURCE = "tasks.nvim"
M.MODES = { "prefill", "run" }
M.KINDS = { "handoff", "review-done", "draft-task", "prepare-decision", "split-plan" }

-- ai-desktop takes a task file of up to 256 KiB; a larger one is refused here, before a request.
M.MAX_MARKDOWN = 256 * 1024
-- The answers are small JSON documents; more than this is not ai-desktop.
local MAX_RESPONSE = 64 * 1024
local TIMEOUT_MS = 5000
local SECRET_BYTES = 4096

---@param list string[]
---@param value any
---@return boolean
local function member(list, value)
  return vim.tbl_contains(list, value)
end

---The control secret of ai-desktop in `dir` (its config folder): 64 lower-case hex digits, or nil and why. The reason
---never holds the content.
---@param dir string
---@return string|nil secret
---@return string|nil err
function M.read_secret(dir)
  local path = vim.fs.joinpath(dir, "control.secret")
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil,
      "ai-desktop has no control.secret in "
        .. dir
        .. " (an older version, or it could not write it)"
  end
  if stat.size > SECRET_BYTES then
    return nil, "the control.secret of ai-desktop is not a secret of ai-desktop (too large)"
  end
  local file = io.open(path, "rb")
  if not file then
    return nil, "cannot read the control.secret of ai-desktop"
  end
  local text = vim.trim(file:read(SECRET_BYTES) or "")
  file:close()
  if not text:match("^%x+$") or #text ~= 64 then
    return nil, "the control.secret of ai-desktop is not 64 hex digits"
  end
  return text:lower(), nil
end

---The body of `POST /jobs` for a task.
---@param task { id: string, title?: string, area?: string }
---@param root string The vault folder.
---@param markdown string The task file.
---@param mode string
---@param kind string
---@return table
function M.payload(task, root, markdown, mode, kind)
  local area = task.area or task.id:match("^([^/]+)/")
  return {
    source = M.SOURCE,
    task_id = task.id,
    title = (task.title and task.title ~= "") and task.title or task.id,
    markdown = markdown,
    vault = vim.fs.normalize(root),
    area = area,
    mode = mode,
    kind = kind,
  }
end

---Undoes `Transfer-Encoding: chunked`; nil when the body is not well formed.
---@param body string
---@return string|nil
local function unchunk(body)
  local out, pos = {}, 1
  while true do
    local size_hex, after = body:match("^(%x+)[^\r\n]*\r\n()", pos)
    if not size_hex then
      return nil
    end
    local size = tonumber(size_hex, 16)
    if size == 0 then
      return table.concat(out)
    end
    out[#out + 1] = body:sub(after, after + size - 1)
    pos = after + size + 2
  end
end

---Parses an HTTP/1.1 response: status, body (de-chunked); nil when it is not one.
---@param text string
---@return { status: integer, body: string }|nil
function M.parse_response(text)
  local status = tonumber(text:match("^HTTP/1%.[01] (%d%d%d)"))
  local head_end = text:find("\r\n\r\n", 1, true)
  if not status or not head_end then
    return nil
  end
  local head = text:sub(1, head_end - 1):lower()
  local body = text:sub(head_end + 4)
  if head:find("\ntransfer%-encoding:%s*chunked") then
    body = unchunk(body)
    if not body then
      return nil
    end
  end
  return { status = status, body = body }
end

---One HTTP request to 127.0.0.1:`port` over `vim.uv` TCP (`Connection: close`, 5 s, 64 KiB at most). `cb(err, res)`
---runs in the main loop; `res` is `{ status, body }`. `headers` is a list of `{ name, value }`.
---@param port integer
---@param method string
---@param path string
---@param headers string[][]
---@param body string
---@param cb fun(err: string|nil, res: { status: integer, body: string }|nil)
function M.request(port, method, path, headers, body, cb)
  local tcp = vim.uv.new_tcp()
  local timer = vim.uv.new_timer()
  if not tcp or not timer then
    vim.schedule(function()
      cb("no socket", nil)
    end)
    return
  end
  local chunks, size, done = {}, 0, false
  local function finish(err, res)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    if not tcp:is_closing() then
      tcp:close()
    end
    vim.schedule(function()
      cb(err, res)
    end)
  end
  timer:start(TIMEOUT_MS, 0, function()
    finish(("no answer from 127.0.0.1:%d within %d s"):format(port, TIMEOUT_MS / 1000))
  end)
  -- A connect that fails at once (a port libuv refuses) returns its error here and calls no callback.
  local started, start_err = tcp:connect("127.0.0.1", port, function(cerr)
    if cerr then
      finish(("cannot connect to 127.0.0.1:%d (%s)"):format(port, cerr))
      return
    end
    local lines = {
      ("%s %s HTTP/1.1"):format(method, path),
      ("Host: 127.0.0.1:%d"):format(port),
      "Connection: close",
      ("Content-Length: %d"):format(#body),
    }
    for _, header in ipairs(headers) do
      lines[#lines + 1] = header[1] .. ": " .. header[2]
    end
    tcp:read_start(function(rerr, data)
      if rerr then
        finish("the connection broke (" .. tostring(rerr) .. ")")
      elseif data then
        size = size + #data
        if size > MAX_RESPONSE then
          finish("the answer is larger than an answer of ai-desktop")
          return
        end
        chunks[#chunks + 1] = data
      else
        local res = M.parse_response(table.concat(chunks))
        if res then
          finish(nil, res)
        else
          finish("the answer is not HTTP", nil)
        end
      end
    end)
    tcp:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. body)
  end)
  if not started then
    finish(("cannot connect to 127.0.0.1:%d (%s)"):format(port, tostring(start_err)))
  end
end

local ffi_declared = false

---Windows: lets the process `pid` bring its window to the front (the foreground lock lets only the process with the
---person's last input do that; a terminal's nvim usually is not it, then this does nothing). False elsewhere or when it
---did not take.
---@param pid integer
---@return boolean
function M.allow_foreground(pid)
  if vim.fn.has("win32") ~= 1 then
    return false
  end
  local has_ffi, ffi = pcall(require, "ffi")
  if not has_ffi then
    return false
  end
  if not ffi_declared then
    pcall(ffi.cdef, "int AllowSetForegroundWindow(unsigned long dwProcessId);")
    ffi_declared = true
  end
  local loaded, user32 = pcall(ffi.load, "user32")
  if not loaded then
    return false
  end
  local called, result = pcall(function()
    return user32.AllowSetForegroundWindow(pid)
  end)
  return called and result ~= 0
end

---A JSON object of an answer, or nil.
---@param body string
---@return table|nil
local function decode(body)
  local good, doc = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  return (good and type(doc) == "table") and doc or nil
end

---The message of an error answer of ai-desktop (`{ error: { message } }`), cut to one line.
---@param res { status: integer, body: string }
---@return string
local function answer_error(res)
  local doc = decode(res.body)
  local message = doc and type(doc.error) == "table" and doc.error.message
  if type(message) ~= "string" or message == "" then
    message = "HTTP " .. res.status
  end
  return (message:gsub("[\r\n].*$", ""):sub(1, 300))
end

---@class Tasks.AgentResult
---@field job_id string
---@field status string   prefilled | running | needs_confirmation
---@field private boolean
---@field note string|nil

---Hands a task to the running ai-desktop. `cb(err, result)` in the main loop. `deps` replaces parts for the specs:
---`record` (the `hub.json` record), `config_dir`, `request`, `allow_foreground`.
---@param payload table The body (`M.payload`).
---@param cb fun(err: string|nil, result: Tasks.AgentResult|nil)
---@param deps? table
function M.hand_over(payload, cb, deps)
  deps = deps or {}
  local ai = require("tasks_nvim.ai")
  local record = deps.record or ai.hub_record()
  if not record then
    cb("ai-desktop is not running", nil)
    return
  end
  if not member(M.MODES, payload.mode) or not member(M.KINDS, payload.kind) then
    cb("mode or kind is not one ai-desktop takes", nil)
    return
  end
  if #payload.markdown > M.MAX_MARKDOWN then
    cb(
      ("the task file is larger than %d KiB, ai-desktop takes no more"):format(
        M.MAX_MARKDOWN / 1024
      ),
      nil
    )
    return
  end
  local request = deps.request or M.request
  request(record.port, "GET", "/health", {}, "", function(herr, health)
    if herr then
      cb("ai-desktop does not answer: " .. herr, nil)
      return
    end
    local doc = health.status == 200 and decode(health.body) or nil
    if
      not doc
      or doc.app ~= "ai-desktop"
      or (record.instance ~= "" and doc.instance ~= record.instance)
    then
      cb(
        ("the program on port %d is not the ai-desktop of hub.json; nothing was sent"):format(
          record.port
        ),
        nil
      )
      return
    end
    local secret, serr = M.read_secret(deps.config_dir or ai.config_dir() or "")
    if not secret then
      cb(serr, nil)
      return
    end
    local allow = deps.allow_foreground or M.allow_foreground
    allow(record.pid)
    request(
      record.port,
      "POST",
      "/jobs",
      {
        { "Authorization", "Bearer " .. secret },
        { "Content-Type", "application/json" },
      },
      vim.json.encode(payload),
      function(perr, res)
        if perr then
          cb("the hand-over failed: " .. perr, nil)
          return
        end
        if res.status ~= 201 then
          cb(("ai-desktop refused the task (%d): %s"):format(res.status, answer_error(res)), nil)
          return
        end
        local answer = decode(res.body)
        if not answer or type(answer.job_id) ~= "string" or type(answer.status) ~= "string" then
          cb("ai-desktop answered, but not with a job", nil)
          return
        end
        cb(nil, {
          job_id = answer.job_id,
          status = answer.status,
          private = answer.private == true,
          note = type(answer.note) == "string" and answer.note or nil,
        })
      end
    )
  end)
end

---The prompt for ai.nvim when there is no ai-desktop: one answer, no tools.
---@param payload table
---@return string
function M.prompt(payload)
  return ("Task %s of the task vault (area %s, kind %s). Work out how to do it: the steps, the files or places "):format(
    payload.task_id,
    payload.area,
    payload.kind
  ) .. "concerned, the open questions. Answer in the language of the task.\n\n" .. payload.markdown
end

return M
