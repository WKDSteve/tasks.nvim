---@module 'tasks_nvim.sources'
---@brief The web links of a learning path's `## Quellen` table: ask whether they still answer, fill the column `Geprüft`.
---@description
--- A learning path lists its sources in a table (`| Quelle | Typ | Worauf achten | Zugang | Geprüft |`, LP-07). This module
--- reads the table, sends one HEAD request per `http(s)` link of the first column (a GET when the server refuses HEAD),
--- and sorts the answers: `ok`, `redirected` (the link works but moved), `blocked` (401, 403, 429: a server that
--- shuts out a program and may still open in a browser, so neither dead nor checkable), `dead` (404, 410), `error`
--- (any other 4xx or 5xx) and `unreachable` (no answer, a timeout). `write` puts the date and the answer into the cell
--- `Geprüft` of each row it asked about.
---
--- The requests go out through `curl` (an `https` link needs TLS) and ONLY when a caller asks: `tasks check --sources`.
--- Neither `check` without that flag nor the hook of the vault ever reaches this module. Local links stay with
--- `path-link-missing`.
---
--- Not its job: the files of the vault (the caller names them), checking local files, the exit status.

local fsio = require("tasks_nvim.fsio")
local mdlinks = require("tasks_nvim.mdlinks")

local M = {}

---@alias Tasks.SourceState "ok"|"redirected"|"blocked"|"dead"|"error"|"unreachable"

---@class Tasks.SourceRow
---@field line integer     # 1-based line of the table row.
---@field url string       # The first `http(s)` link of the first cell.
---@field cells string[]   # The cells of the row, trimmed.
---@field col integer      # Index of the cell `Geprüft`.

---@class Tasks.SourceProbe
---@field code integer      # The status of the last response; 0 for none.
---@field redirects integer # How many redirects were followed.
---@field final string      # The address the last response came from.
---@field timeout boolean   # No answer within the time limit.
---@field method "HEAD"|"GET"

---@class Tasks.SourceResult : Tasks.SourceProbe
---@field row Tasks.SourceRow
---@field state Tasks.SourceState

M.DEFAULT_TIMEOUT = 8
M.CONCURRENCY = 6

---The cells of a table row: split at the pipes that are no escaped `\|`, trimmed.
---@param line string
---@return string[]
local function cells_of(line)
  local body = vim.trim(line):gsub("^|", ""):gsub("|$", "")
  local out, cur, i = {}, {}, 1
  local bs = string.char(92)
  while i <= #body do
    local c = body:sub(i, i)
    if c == bs and body:sub(i + 1, i + 1) == "|" then
      cur[#cur + 1] = bs .. "|"
      i = i + 2
    elseif c == "|" then
      out[#out + 1] = vim.trim(table.concat(cur))
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  out[#out + 1] = vim.trim(table.concat(cur))
  return out
end

---The rows of the `## Quellen` table that carry a web link, with the column `Geprüft` found by its heading. A table
---without that column has no rows to report on (nothing to fill).
---@param text string
---@return Tasks.SourceRow[]
function M.rows(text)
  local out = {}
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  local in_section, col, fence = false, nil, false
  for lnum, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence then
      local heading = line:match("^##%s+(.-)%s*$")
      if heading then
        in_section = heading:lower() == "quellen"
        col = nil
      elseif in_section and line:match("^%s*|") then
        local cells = cells_of(line)
        if not col then
          for i, c in ipairs(cells) do
            local name = c:lower()
            if name == "geprüft" or name == "geprueft" then
              col = i
            end
          end
        elseif not line:match("^%s*|[%s:|-]+$") and #cells >= col then
          local links = mdlinks.scan(cells[1])
          local url
          for _, l in ipairs(links) do
            if l.target:match("^https?://") then
              url = l.target
              break
            end
          end
          url = url or cells[1]:match("<?(https?://[^%s<>|)]+)")
          if url then
            out[#out + 1] = { line = lnum, url = url, cells = cells, col = col }
          end
        end
      end
    end
  end
  return out
end

---What the status of an answer means.
---@param p Tasks.SourceProbe
---@return Tasks.SourceState
function M.classify(p)
  local code = p.code
  if p.timeout or code == 0 then
    return "unreachable"
  elseif code >= 200 and code < 300 then
    return p.redirects > 0 and "redirected" or "ok"
  elseif code == 401 or code == 403 or code == 429 then
    return "blocked"
  elseif code == 404 or code == 410 then
    return "dead"
  end
  return "error"
end

local function null_device()
  return vim.uv.os_uname().sysname:find("Windows", 1, true) and "NUL" or "/dev/null"
end

---The arguments of one request. Only `http(s)` is spoken, also after a redirect.
---@param url string
---@param method "HEAD"|"GET"
---@param timeout integer
---@return string[]
local function curl_args(url, method, timeout)
  local args = {
    "curl",
    "-sS",
    "-L",
    "--max-redirs",
    "5",
    "--max-time",
    tostring(timeout),
    "--proto",
    "=http,https",
    "--proto-redir",
    "=http,https",
    "-A",
    "tasks.nvim-sources-check",
    "-o",
    null_device(),
    "-w",
    "%{http_code} %{num_redirects} %{url_effective}",
  }
  if method == "HEAD" then
    args[#args + 1] = "-I"
  else
    vim.list_extend(args, { "--range", "0-0", "--max-filesize", "1048576" })
  end
  vim.list_extend(args, { "--url", url })
  return args
end

---One request, asynchronously.
---@param url string
---@param method "HEAD"|"GET"
---@param timeout integer
---@param done fun(p: Tasks.SourceProbe)
local function request(url, method, timeout, done)
  local ok, err = pcall(vim.system, curl_args(url, method, timeout), { text = true }, function(res)
    local code, redirects, final = (res.stdout or ""):match("^(%d+) (%d+) (.*)$")
    done({
      code = tonumber(code) or 0,
      redirects = tonumber(redirects) or 0,
      final = final or url,
      timeout = res.code == 28,
      method = method,
    })
  end)
  if not ok then
    done({
      code = 0,
      redirects = 0,
      final = url,
      timeout = false,
      method = method,
      err = tostring(err),
    })
  end
end

---Ask about one address: HEAD first, a GET when the server answers 400 or more (many refuse HEAD) and did not time out.
---@param url string
---@param timeout integer
---@param done fun(p: Tasks.SourceProbe)
function M.probe(url, timeout, done)
  request(url, "HEAD", timeout, function(head)
    if head.code >= 400 and not head.timeout then
      request(url, "GET", timeout, done)
    else
      done(head)
    end
  end)
end

---Ask about the web links of a path file's Quellen table (at most `M.CONCURRENCY` at a time). Blocks until all answered.
---@param text string
---@param opts? { timeout?: integer, probe?: fun(url: string, timeout: integer, done: fun(p: Tasks.SourceProbe)) }
---@return Tasks.SourceResult[]
function M.check_text(text, opts)
  opts = opts or {}
  local timeout = opts.timeout or M.DEFAULT_TIMEOUT
  local probe = opts.probe or M.probe
  local rows = M.rows(text)
  local results, next_i, running, finished = {}, 1, 0, 0
  local function pump()
    while running < M.CONCURRENCY and next_i <= #rows do
      local row = rows[next_i]
      local at = next_i
      next_i = next_i + 1
      running = running + 1
      probe(row.url, timeout, function(p) ---@cast p Tasks.SourceResult
        vim.schedule(function()
          p.row = row
          p.state = M.classify(p)
          results[at] = p
          running = running - 1
          finished = finished + 1
          pump()
        end)
      end)
    end
  end
  pump()
  vim.wait((timeout * 2 + 5) * 1000 * math.ceil(#rows / M.CONCURRENCY + 1), function()
    return finished >= #rows
  end, 20)
  for i, row in ipairs(rows) do
    results[i] = results[i]
      or {
        row = row,
        state = "unreachable",
        code = 0,
        redirects = 0,
        final = row.url,
        timeout = true,
        method = "HEAD",
      }
  end
  return results
end

---The words of the column `Geprüft` for an answer.
---@param r Tasks.SourceResult
---@param today string
---@return string
function M.cell(r, today)
  local state = r.state
  if state == "ok" then
    return "erreichbar " .. today
  elseif state == "redirected" then
    return "erreichbar (umgeleitet) " .. today
  elseif state == "blocked" then
    return ("abweisend, nicht prüfbar (%d) %s"):format(r.code, today)
  elseif state == "dead" then
    return ("tot (%d) %s"):format(r.code, today)
  elseif state == "error" then
    return ("Fehler (%d) %s"):format(r.code, today)
  end
  return (r.timeout and "keine Antwort (Zeitlimit) " or "keine Antwort ") .. today
end

---The text with the cell `Geprüft` of each answered row replaced; every other byte stays (line endings included).
---@param text string
---@param results Tasks.SourceResult[]
---@param today string
---@return string
function M.write_text(text, results, today)
  local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  for _, r in ipairs(results) do
    local cells = vim.deepcopy(r.row.cells)
    cells[r.row.col] = M.cell(r, today)
    lines[r.row.line] = "| " .. table.concat(cells, " | ") .. " |"
  end
  return table.concat(lines, eol)
end

---Ask about the links of one file and, with `write`, put the answers into it.
---@param path string
---@param opts? { timeout?: integer, write?: boolean, today?: string, probe?: function }
---@return Tasks.SourceResult[]|nil results
---@return string|nil err
function M.check_file(path, opts)
  opts = opts or {}
  local text, err = fsio.read(path)
  if not text then
    return nil, ("cannot read %s: %s"):format(path, tostring(err))
  end
  local results = M.check_text(text, opts)
  if opts.write and #results > 0 then
    -- the file is read again right before it is written: an edit made while the requests ran is not overwritten
    if fsio.read(path) ~= text then
      return nil,
        ("%s changed while its links were being checked; nothing was written, run it again"):format(
          path
        )
    end
    local ok, werr =
      fsio.write_atomic(path, M.write_text(text, results, opts.today or os.date("%Y-%m-%d")))
    if not ok then
      return nil, ("cannot write %s: %s"):format(path, tostring(werr))
    end
  end
  return results, nil
end

return M
