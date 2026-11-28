---@module 'tasks_nvim.sources'
---@brief The web links of a learning path's `## Quellen` table: ask whether they still answer, fill the column `Geprüft`.
---@description
--- A learning path lists its sources in a table (`| Quelle | Typ | Worauf achten | Zugang | Geprüft |`, LP-07). This module
--- reads the table, sends one HEAD request per `http(s)` link of the first column (a GET when the server refuses HEAD),
--- and sorts the answers: `ok`, `redirected` (the link works but moved), `blocked` (401, 403, 429: a server that
--- shuts out a program and may still open in a browser, so neither dead nor checkable), `dead` (404, 410), `error`
--- (any other 4xx or 5xx), `unreachable` (no answer, a timeout) and `unverified` (a 2xx from a host that answers 200
--- for any path, a single-page app such as `help.sap.com`: alive or dead shows only in a browser; `SPA_HOSTS`). `write` puts the date and the answer into the cell
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

---@alias Tasks.SourceState "ok"|"redirected"|"blocked"|"dead"|"error"|"unreachable"|"unverified"

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
---@field fixed? string      # `fix`: the address a permanent redirect (301, 308) leads to; the link is rewritten to it.
---@field kept? string       # `fix`: why a moved link was left as it is.
---@field broader? boolean   # `redirected` to a broader page of the same host (`M.broader`).

M.DEFAULT_TIMEOUT = 8
M.CONCURRENCY = 6

---Hosts known to answer 200 for any path (single-page apps that render "not found" in the browser): a 2xx from them
---says nothing, so the row is `unverified`. Compared like `safe_target` does (lower case, without `www.` and port);
---`check --sources --spa-host=<host,...>` adds more for one run. No host here offers a machine-readable check of a page.
M.SPA_HOSTS = { "help.sap.com" }

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

local host_of

---What the status of an answer means. A 2xx whose last address is on one of `spa_hosts` (default `M.SPA_HOSTS`) is
---`unverified`: such a host answers 200 for a page that does not exist.
---@param p Tasks.SourceProbe
---@param spa_hosts? string[]
---@return Tasks.SourceState
function M.classify(p, spa_hosts)
  local code = p.code
  if p.timeout or code == 0 then
    return "unreachable"
  elseif code >= 200 and code < 300 then
    local host = p.final and host_of(p.final) or ""
    for _, h in ipairs(spa_hosts or M.SPA_HOSTS) do
      if host ~= "" and host == host_of("https://" .. h) then
        return "unverified"
      end
    end
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

---The first hop of one address, not followed: its status and where it points (curl makes the address absolute).
---@param url string
---@param timeout integer
---@param done fun(code: integer, location: string)
local function hop(url, timeout, done)
  local args = {
    "curl",
    "-sS",
    "-I",
    "--max-time",
    tostring(timeout),
    "--proto",
    "=http,https",
    "-A",
    "tasks.nvim-sources-check",
    "-o",
    null_device(),
    "-w",
    "%{http_code} %{redirect_url}",
    "--url",
    url,
  }
  local ok = pcall(vim.system, args, { text = true }, function(res)
    local code, loc = (res.stdout or ""):match("^(%d+) ?(.*)$")
    done(tonumber(code) or 0, loc or "")
  end)
  if not ok then
    done(0, "")
  end
end

---The host of an `http(s)` address for comparing: lower case, no user info, no port, no leading `www.`.
---@param url string
---@return string
function host_of(url)
  local auth = (url:match("^https?://([^/?#]*)") or ""):gsub("^.*@", ""):gsub(":%d*$", "")
  return (auth:lower():gsub("^www%.", ""))
end

---Whether the address a redirect leads to may be written into the table in place of the old one: a plain `http(s)`
---address without anything that would break a Markdown link or a table cell, no step back from `https` to `http`, and
---not the front page of a site the old link went deeper into (that is usually a page that is gone). A target on
---ANOTHER HOST (compared without user info, port, a leading `www.` and case) is only taken with `allow_host_change`:
---a domain that changed hands may redirect anywhere, so a person looks at it first.
---@param old string
---@param new string
---@param allow_host_change? boolean
---@return boolean ok
---@return string? reason
function M.safe_target(old, new, allow_host_change)
  if not new:match("^https?://[%w%-._~:/?#%[%]@!$&*+,;=%%]+$") then
    return false, "the target is not a plain address"
  elseif old:match("^https://") and new:match("^http://") then
    return false, "the target is http, the link is https"
  end
  if not allow_host_change and host_of(old) ~= host_of(new) then
    return false, "other host, check by hand (--allow-host-change)"
  end
  local old_path = (old:match("^https?://[^/?#]*(.*)$") or ""):gsub("[#?].*$", "")
  local new_path = (new:match("^https?://[^/?#]*(.*)$") or ""):gsub("[#?].*$", "")
  if #old_path > 1 and #new_path <= 1 then
    return false, "the target is the front page"
  end
  return true
end

---The path of an `http(s)` address without query and fragment ("" for none).
---@param url string
---@return string
local function path_of(url)
  return ((url:match("^https?://[^/?#]*(.*)$") or ""):gsub("[#?].*$", ""))
end

---The query of an address without its fragment ("" for none).
---@param url string
---@return string
local function query_of(url)
  return ((url:gsub("#.*$", "")):match("%?(.*)$") or "")
end

---Whether a path segment names a version or a date: `2026-07-28`, `v2`, `v2.1`, `1.2.3`.
---@param seg string
---@return boolean
local function versioned(seg)
  return seg:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
    or seg:match("^[vV]%d+$") ~= nil
    or seg:match("^[vV]?%d+%.%d+[%.%d]*$") ~= nil
end

---Why a permanent redirect would pin an evergreen link to today's version, or nil when it does not: a target that
---differs only in its query (the server added its default `?view=...`), or a target path that carries a version or
---date segment the old path did not have (a front page that lands on `/docs/2026-07-28/...`, `latest` turned into a
---number). Both follow the server's current default, so the link would stay behind when it moves on.
---@param old string
---@param new string
---@return string|nil reason
function M.pins_version(old, new)
  if
    host_of(old) == host_of(new)
    and path_of(old) == path_of(new)
    and query_of(old) ~= query_of(new)
  then
    return "only a query was added"
  end
  local had = {}
  for seg in path_of(old):gmatch("[^/]+") do
    had[seg] = true
  end
  for seg in path_of(new):gmatch("[^/]+") do
    if versioned(seg) and not had[seg] then
      return "target path carries a version or date"
    end
  end
  return nil
end

---Whether a redirect leads from a page to a broader one on the same host: a target path with fewer segments in the
---same section (the first segment), a parent of the old path among them. The new page may still mention the topic,
---but it is the overview of a whole area, so the link no longer points at what it was written for (a front page has a
---rule of its own in `safe_target`).
---@param old string
---@param new string
---@return boolean
function M.broader(old, new)
  if host_of(old) ~= host_of(new) then
    return false
  end
  local o, n = {}, {}
  for seg in path_of(old):gmatch("[^/]+") do
    o[#o + 1] = seg
  end
  for seg in path_of(new):gmatch("[^/]+") do
    n[#n + 1] = seg
  end
  return #n > 0 and #n < #o and n[1] == o[1]
end

---Follow an address by hand and return where its PERMANENT redirects (301, 308) lead: a temporary one (302, 303, 307)
---ends the walk, as does a plain answer. At most 5 hops. nil: it is not moved for good.
---@param url string
---@param timeout integer
---@param done fun(target: string|nil)
function M.permanent_target(url, timeout, done)
  local last, cur, left = nil, url, 5
  local function step()
    hop(cur, timeout, function(code, loc)
      if (code == 301 or code == 308) and loc ~= "" and left > 0 then
        left = left - 1
        last, cur = loc, loc
        step()
      else
        done(last)
      end
    end)
  end
  step()
end

---Mark what `fix` does for each moved link: `fixed` (the new address) or `kept` (the reason). Blocks until all asked.
---@param results Tasks.SourceResult[]
---@param timeout integer
---@param resolve? fun(url: string, timeout: integer, done: fun(target: string|nil))
---@param allow_host_change? boolean
---@param allow_version_pin? boolean
---@param allow_broader? boolean
local function resolve_moved(
  results,
  timeout,
  resolve,
  allow_host_change,
  allow_version_pin,
  allow_broader
)
  resolve = resolve or M.permanent_target
  for _, r in ipairs(results) do
    if r.state == "redirected" then
      local answered, target = false, nil
      resolve(r.row.url, timeout, function(t)
        target, answered = t, true
      end)
      vim.wait((timeout * 6 + 5) * 1000, function()
        return answered
      end, 20)
      if not target then
        r.kept = "no permanent redirect (301, 308)"
      else
        local frag = r.row.url:match("(#[^#]*)$")
        if frag and not target:find("#", 1, true) then
          target = target .. frag
        end
        local ok, why = M.safe_target(r.row.url, target, allow_host_change)
        local pin = ok and not allow_version_pin and M.pins_version(r.row.url, target) or nil
        if not ok then
          r.kept = why
        elseif pin then
          r.kept = pin .. " (--allow-version-pin)"
        elseif not allow_broader and M.broader(r.row.url, target) then
          r.kept = "broader page: check by hand (--allow-broader)"
        elseif target == r.row.url then
          r.kept = "same address"
        else
          r.fixed = target
        end
      end
    end
  end
end

---Ask about the web links of a path file's Quellen table (at most `M.CONCURRENCY` at a time). Blocks until all answered.
---@param text string
---@param opts? { timeout?: integer, fix?: boolean, allow_host_change?: boolean, allow_version_pin?: boolean, allow_broader?: boolean, spa_hosts?: string[], resolve?: function, probe?: fun(url: string, timeout: integer, done: fun(p: Tasks.SourceProbe)) }
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
          p.state = M.classify(p, opts.spa_hosts)
          -- seen before anything is written: the `redirected` line says so
          p.broader = p.state == "redirected" and M.broader(row.url, p.final) or nil
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
  if opts.fix then
    resolve_moved(
      results,
      timeout,
      opts.resolve,
      opts.allow_host_change,
      opts.allow_version_pin,
      opts.allow_broader
    )
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
  elseif state == "unverified" then
    return "Single-Page-App, Inhalt im Browser prüfen " .. today
  end
  return (r.timeout and "keine Antwort (Zeitlimit) " or "keine Antwort ") .. today
end

---`s` with every plain occurrence of `old` replaced by `new`.
---@param s string
---@param old string
---@param new string
---@return string
local function replace_plain(s, old, new)
  local out, from = {}, 1
  while true do
    local a, b = s:find(old, from, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(from, a - 1)
    out[#out + 1] = new
    from = b + 1
  end
  out[#out + 1] = s:sub(from)
  return table.concat(out)
end

---The text with the rows changed that were asked about; every other byte stays (line endings included). With
---`opts.write` the cell `Geprüft` of each answered row is replaced (the row is written anew from its cells); with
---`opts.fix` the address of a row with a `fixed` target is replaced in the link (a row without `write` keeps its bytes).
---@param text string
---@param results Tasks.SourceResult[]
---@param opts { today?: string, write?: boolean, fix?: boolean }
---@return string
function M.apply(text, results, opts)
  local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  for _, r in ipairs(results) do
    local fixed = opts.fix and r.fixed or nil
    if opts.write then
      local cells = vim.deepcopy(r.row.cells)
      cells[r.row.col] = M.cell(r, opts.today or os.date("%Y-%m-%d"))
      if fixed then
        cells[1] = replace_plain(cells[1], r.row.url, fixed)
      end
      lines[r.row.line] = "| " .. table.concat(cells, " | ") .. " |"
    elseif fixed then
      lines[r.row.line] = replace_plain(lines[r.row.line], r.row.url, fixed)
    end
  end
  return table.concat(lines, eol)
end

---The text with the cell `Geprüft` of each answered row replaced (`apply` with `write`).
---@param text string
---@param results Tasks.SourceResult[]
---@param today string
---@return string
function M.write_text(text, results, today)
  return M.apply(text, results, { write = true, today = today })
end

---Ask about the links of one file and, with `write`, put the answers into it.
---@param path string
---@param opts? { timeout?: integer, write?: boolean, fix?: boolean, allow_host_change?: boolean, allow_version_pin?: boolean, allow_broader?: boolean, spa_hosts?: string[], today?: string, probe?: function, resolve?: function }
---@return Tasks.SourceResult[]|nil results
---@return string|nil err
function M.check_file(path, opts)
  opts = opts or {}
  local text, err = fsio.read(path)
  if not text then
    return nil, ("cannot read %s: %s"):format(path, tostring(err))
  end
  local results = M.check_text(text, opts)
  if (opts.write or opts.fix) and #results > 0 then
    -- the file is read again right before it is written: an edit made while the requests ran is not overwritten
    if fsio.read(path) ~= text then
      return nil,
        ("%s changed while its links were being checked; nothing was written, run it again"):format(
          path
        )
    end
    local ok, werr = fsio.write_atomic(
      path,
      M.apply(text, results, { write = opts.write, fix = opts.fix, today = opts.today })
    )
    if not ok then
      return nil, ("cannot write %s: %s"):format(path, tostring(werr))
    end
  end
  return results, nil
end

return M
