---@module 'tasks_nvim.claims'
---@brief Reservation of a task for the time somebody works on it (a claim), so two agents do not take the same task.
---@description
--- A claim says WHO works on an open task, SINCE when and UNTIL when (it expires: a chat that died blocks nothing for
--- longer than its duration). It is kept in a small file outside the task files, `<vault>/.claims/<area>/<slug>.json`
--- (`{ by, since, until, note? }`, UTC, seconds), next to a `.gitignore` of `*`: a claim lives on this machine, makes no
--- commit noise and is no part of the vault's data. The task keeps `status: doing` as the visible sign.
---
---  - `acquire` / `release`   the two verbs (CLI `claim`, `release`); both run under the task file's lock, the very lock
---                            `set`, `done` and the text edits hold, so reserving and changing a task never interleave
---  - `guard`                 the one check every write path calls: a valid claim of somebody else refuses the write
---                            (`--force` with a note overrides it)
---  - `state`                 `free | own | foreign | expired`
---  - `list` / `read`         the claims of a vault / of one task; reading creates no folder
---
--- Time comes from outside (`opts.now`, default `claims.now()`), so expiry is tested without waiting. The store is read
--- and written only here: another backend (a frontmatter field, say) would replace the functions of the "store" part.
---
--- Not its job: the task's own fields (`mutate`), the choice of the next task (`next_pick` reads `list`), messages.

local fsio = require("tasks_nvim.fsio")
local vault = require("tasks_nvim.vault")

local M = {}

---The folder of the claims, in the vault root.
M.DIR = ".claims"

---How long a claim lasts when nothing is said (4 hours), and the longest it may last (24 hours), in seconds.
M.DEFAULT_SECONDS = 4 * 3600
M.MAX_SECONDS = 24 * 3600

---@class Tasks.Claim
---@field by string      # Who: free text, 1 to 64 characters of letters, digits and `. _ : - @`.
---@field since string   # `YYYY-MM-DDTHH:MM:SSZ`
---@field until_ string  # `YYYY-MM-DDTHH:MM:SSZ` (in the file: `until`)
---@field note? string

-- ── time ─────────────────────────────────────────────────────────────────────

---Days since 1970-01-01 of a civil date (proleptic Gregorian).
---@param y integer
---@param m integer
---@param d integer
---@return integer
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

---`2026-11-07T12:00:00Z` to seconds since the epoch.
---@param iso any
---@return integer|nil
function M.parse_time(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not y then
    return nil
  end
  local year, month, day = tonumber(y), tonumber(mo), tonumber(d)
  local hour, min, sec = tonumber(h), tonumber(mi), tonumber(s)
  if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or min > 59 or sec > 60 then
    return nil
  end
  return days_from_civil(year, month, day) * 86400 + hour * 3600 + min * 60 + sec
end

---@param epoch integer
---@return string
local function format_time(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch) --[[@as string]]
end

---Now, UTC, to the second.
---@return string
function M.now()
  return format_time(os.time())
end

---`iso` plus some seconds.
---@param iso string
---@param seconds integer
---@return string|nil
function M.add_seconds(iso, seconds)
  local t = M.parse_time(iso)
  return t and format_time(t + seconds) or nil
end

---A duration (`90s`, `30m`, `2h`, `1d`, a bare number of seconds) in seconds.
---@param text any
---@return integer|nil seconds
---@return string|nil err
function M.parse_duration(text)
  local n, unit = tostring(text):match("^(%d+)([smhd]?)$")
  if not n then
    return nil, ("duration '%s' is not like 90m, 2h or 1d"):format(tostring(text))
  end
  local seconds = tonumber(n) * ({ [""] = 1, s = 1, m = 60, h = 3600, d = 86400 })[unit]
  if seconds < 1 then
    return nil, "duration must be longer than zero"
  end
  if seconds > M.MAX_SECONDS then
    return nil, ("a claim lasts at most %d hours"):format(M.MAX_SECONDS / 3600)
  end
  return seconds, nil
end

-- ── names ────────────────────────────────────────────────────────────────────

---@param by any
---@return boolean
function M.valid_name(by)
  return type(by) == "string" and #by >= 1 and #by <= 64 and by:match("^[%w._:@-]+$") ~= nil
end

---The name when nobody gives one: `cdx:<8 characters of $CLAUDE_CODE_SESSION_ID>` inside a Claude Code session, else
---`<user>@<host>`. An agent should still pass `--by` (a sub-agent may share the session's id).
---@return string
function M.default_name()
  local session = vim.env.CLAUDE_CODE_SESSION_ID
  if type(session) == "string" then
    local short = session:gsub("[^%w]", ""):sub(1, 8)
    if short ~= "" then
      return "cdx:" .. short
    end
  end
  local uv = vim.uv or vim.loop
  local pw = uv.os_get_passwd and uv.os_get_passwd()
  local user = pw and pw.username or "user"
  local host = uv.os_gethostname and uv.os_gethostname() or "host"
  local name = (user .. "@" .. host):gsub("[^%w._:@-]", "-")
  return name:sub(1, 64)
end

-- ── the store: one JSON file per claim ───────────────────────────────────────

---@param root string
---@param id string
---@return string|nil path
local function claim_path(root, id)
  local area, slug = vault.parse_id(id)
  if not area or not slug then
    return nil
  end
  return ("%s/%s/%s/%s.json"):format(root, M.DIR, area, slug)
end

---@param text string
---@return Tasks.Claim|nil
local function decode(text)
  local ok, doc = pcall(vim.json.decode, text)
  if not ok or type(doc) ~= "table" then
    return nil
  end
  if not (M.valid_name(doc.by) and M.parse_time(doc.since) and M.parse_time(doc["until"])) then
    return nil
  end
  return {
    by = doc.by,
    since = doc.since,
    until_ = doc["until"],
    note = type(doc.note) == "string" and doc.note or nil,
  }
end

---The claim of a task. A file that is no claim is none (a damaged file blocks nobody).
---@param root string
---@param id string
---@return Tasks.Claim|nil claim
---@return string|nil etag  # of the claim file
function M.read(root, id)
  local path = claim_path(root, id)
  if not path or not fsio.is_file(path) then
    return nil, nil
  end
  local text = fsio.read(path)
  local claim = text and decode(text)
  if not claim then
    return nil, nil
  end
  return claim, fsio.etag(text)
end

---Every claim of the vault, by task id. Reads only: no folder is made.
---@param root string
---@return table<string, Tasks.Claim>
function M.list(root)
  local out = {}
  local base = root .. "/" .. M.DIR
  local uv = vim.uv or vim.loop
  local areas = uv.fs_scandir(base)
  if not areas then
    return out
  end
  while true do
    local area, kind = uv.fs_scandir_next(areas)
    if not area then
      break
    end
    -- a file system that does not say the type (`nil`) is asked by listing the entry
    if (kind == "directory" or kind == nil) and vault.valid_area(area) then
      local files = uv.fs_scandir(base .. "/" .. area)
      while files do
        local name = uv.fs_scandir_next(files)
        if not name then
          break
        end
        local slug = name:match("^(.+)%.json$")
        if slug and vault.valid_slug(slug) then
          local id = area .. "/" .. slug
          local claim = M.read(root, id)
          if claim then
            out[id] = claim
          end
        end
      end
    end
  end
  return out
end

---Write the claim of a task (the folder and its `.gitignore` are made on the first claim).
---@param root string
---@param id string
---@param claim Tasks.Claim
---@return boolean|nil ok
---@return string|nil err
local function write(root, id, claim)
  local path = claim_path(root, id)
  if not path then
    return nil, "invalid task id: " .. tostring(id)
  end
  local ignore = root .. "/" .. M.DIR .. "/.gitignore"
  if not fsio.is_file(ignore) then
    local ok, err = fsio.write_atomic(ignore, "*\n")
    if not ok then
      return nil, "cannot write " .. ignore .. ": " .. tostring(err)
    end
  end
  local doc = ('{\n  "by": %s,\n  "note": %s,\n  "since": %s,\n  "until": %s\n}\n'):format(
    vim.json.encode(claim.by),
    vim.json.encode(claim.note or vim.NIL),
    vim.json.encode(claim.since),
    vim.json.encode(claim.until_)
  )
  if not claim.note then
    doc = doc:gsub('  "note": null,\n', "")
  end
  local ok, err = fsio.write_atomic(path, doc)
  if not ok then
    return nil, "cannot write " .. path .. ": " .. tostring(err)
  end
  return true, nil
end

---Take the claim of a task away (a claim that is not there is no error).
---@param root string
---@param id string
---@return boolean ok
function M.remove(root, id)
  local path = claim_path(root, id)
  if path and fsio.lstat(path) then
    return fsio.remove(path) == true
  end
  return true
end

-- ── the rules ────────────────────────────────────────────────────────────────

---`free` (no claim), `own` (the caller's, valid), `foreign` (somebody else's, valid), `expired` (nobody's any more).
---@param claim Tasks.Claim|nil
---@param by string
---@param now string
---@return "free"|"own"|"foreign"|"expired"
function M.state(claim, by, now)
  if not claim then
    return "free"
  end
  if claim.until_ <= now then
    return "expired"
  end
  return claim.by == by and "own" or "foreign"
end

---@param id string
---@param claim Tasks.Claim
---@return string
local function held_message(id, claim)
  return ("%s is claimed by %s since %s until %s: ask them, wait for the claim to run out, or --force --note=<why>"):format(
    id,
    claim.by,
    claim.since,
    claim.until_
  )
end

---The one check of the write paths: may `opts.by` change the task? A valid claim of somebody else says no, naming the
---owner; `opts.force` with a `opts.note` says yes (the caller then records the override). Everything else is yes.
---@param root string
---@param id string
---@param opts? { by?: string, force?: boolean, note?: string, now?: string, claims_guard?: boolean }
---@return boolean|nil ok
---@return string|nil err
---@return table|nil info  `{ code = "conflict", id }`
function M.guard(root, id, opts)
  opts = opts or {}
  if opts.claims_guard == false then
    return true, nil
  end
  local claim = M.read(root, id)
  if not claim then
    return true, nil
  end
  -- what the call does not say itself, the request around it does
  local who = M.identity or {}
  opts = {
    by = opts.by or who.by,
    force = opts.force or who.force,
    note = opts.note or who.note,
    now = opts.now,
  }
  local by = opts.by or M.default_name()
  local state = M.state(claim, by, opts.now or M.now())
  if state ~= "foreign" then
    return true, nil
  end
  if opts.force then
    if type(opts.note) ~= "string" or vim.trim(opts.note) == "" then
      return nil,
        held_message(id, claim) .. " (--force needs --note=<why>)",
        { code = "conflict", id = id }
    end
    return true, nil
  end
  return nil, held_message(id, claim), { code = "conflict", id = id }
end

---Who is acting, for the write paths that are not handed `by`, `force` and `note` one by one (the ops door sets it around
---each operation of a request). `guard` falls back to it.
---@type { by?: string, force?: boolean, note?: string }|nil
M.identity = nil

---@param saved table|nil
---@param ok boolean
---@return any ...
local function restore_identity(saved, ok, ...)
  M.identity = saved
  if not ok then
    error((...), 0)
  end
  return ...
end

---Run `fn(...)` with `identity` as the acting name (restored afterwards, also when `fn` throws).
---@generic R
---@param identity { by?: string, force?: boolean, note?: string }
---@param fn fun(...): R
---@return R
function M.with_identity(identity, fn, ...)
  local saved = M.identity
  M.identity = identity
  return restore_identity(saved, pcall(fn, ...))
end

---@class Tasks.ClaimOpts
---@field root? string
---@field by? string
---@field for_? string|integer  # Duration: `2h`, `90m`, seconds.
---@field renew? boolean
---@field force? boolean
---@field note? string
---@field now? string
---@field status? string        # `release`: the status a `doing` task gets back (default `open`).

---Reserve a task (and make it `doing`). The same name again renews; an expired claim is taken over; a valid claim of
---somebody else is refused (`force` with a `note` takes it over).
---@param id string
---@param opts? Tasks.ClaimOpts
---@return { id: string, claim: Tasks.Claim, taken_over?: Tasks.Claim, renewed?: boolean }|nil result
---@return string|nil err
---@return table|nil info
function M.acquire(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local scan = require("tasks_nvim.scan")
  local task, ferr = scan.find(id, { root = root })
  if not task then
    return nil, ferr or ("no such open task: " .. tostring(id))
  end
  local by = opts.by or M.default_name()
  if not M.valid_name(by) then
    return nil,
      ("by '%s' is not a name (1 to 64 of letters, digits and . _ : - @)"):format(tostring(by))
  end
  local seconds = M.DEFAULT_SECONDS
  if opts.for_ ~= nil then
    local parsed, perr = M.parse_duration(opts.for_)
    if not parsed then
      return nil, perr
    end
    seconds = parsed
  end
  local now = opts.now or M.now()
  local result
  local locked, lerr, linfo = fsio.with_lock(task.path, function()
    local existing = M.read(root, id)
    local state = M.state(existing, by, now)
    if opts.renew and state ~= "own" then
      return nil, ("%s has no claim of yours to renew"):format(id)
    end
    if state == "foreign" then
      local ok, gerr, ginfo =
        M.guard(root, id, { by = by, force = opts.force, note = opts.note, now = now })
      if not ok then
        return nil, gerr, ginfo
      end
    end
    local since = (state == "own" and existing) and existing.since or now
    local claim = { by = by, since = since, until_ = M.add_seconds(now, seconds), note = opts.note }
    if not claim.until_ then
      return nil, "the clock gave no time"
    end
    local ok, serr = write(root, id, claim)
    if not ok then
      return nil, serr
    end
    result = { id = id, claim = claim }
    if state == "own" then
      result.renewed = true
    elseif state == "foreign" or state == "expired" then
      result.taken_over = existing
    end
    return true, nil
  end)
  if not locked then
    return nil, lerr, linfo
  end
  ---@cast result -nil
  -- the visible sign: `doing` (after the lock: `set` takes it itself, and the guard now sees the caller's own claim)
  if task.status ~= "doing" and task.status ~= "decision" then
    local set, serr, sinfo = require("tasks_nvim.mutate").set(id, { status = "doing" }, {
      root = root,
      by = by,
      today = opts.today,
    })
    if not set then
      M.remove(root, id)
      return nil, "the task could not be set to doing, no claim made: " .. tostring(serr), sinfo
    end
  end
  return result, nil
end

---Give a task back. Only the owner may (or `force` with a `note`); a task that is `doing` goes to `open` (or
---`opts.status`), as nothing says "somebody works on it" any more.
---@param id string
---@param opts? Tasks.ClaimOpts
---@return { id: string, released: boolean, status?: string }|nil result
---@return string|nil err
---@return table|nil info
function M.release(id, opts)
  opts = opts or {}
  local root, rerr = vault.root(opts)
  if not root then
    return nil, rerr
  end
  local scan = require("tasks_nvim.scan")
  local task = scan.find(id, { root = root })
  local claim = M.read(root, id)
  if not task and not claim then
    return nil, "no such open task: " .. tostring(id)
  end
  local by = opts.by or M.default_name()
  local now = opts.now or M.now()
  if claim then
    local ok, gerr, ginfo =
      M.guard(root, id, { by = by, force = opts.force, note = opts.note, now = now })
    if not ok then
      return nil, gerr, ginfo
    end
  end
  local back
  if task and task.status == "doing" then
    back = opts.status or "open"
    local set, serr, sinfo = require("tasks_nvim.mutate").set(id, { status = back }, {
      root = root,
      by = by,
      force = opts.force,
      note = opts.note,
      now = now,
      today = opts.today,
    })
    if not set then
      return nil, serr, sinfo
    end
  end
  local had = claim ~= nil
  M.remove(root, id)
  return { id = id, released = had, status = back }, nil
end

---After a write that went past somebody's claim (`force`): say so in the notes of the task, in the words of the one who
---did it. `before` is the claim as it was; a task that is no longer open (a finish) keeps no such line.
---@param id string
---@param before Tasks.Claim|nil
---@param opts { by?: string, force?: boolean, note?: string, root?: string, today?: string, now?: string }
---@return boolean noted
function M.record_override(id, before, opts)
  if not (opts.force and before and type(opts.note) == "string") then
    return false
  end
  local by = opts.by or M.default_name()
  if M.state(before, by, opts.now or M.now()) ~= "foreign" then
    return false
  end
  local mutate = require("tasks_nvim.mutate")
  local text = ("claim of %s overridden by %s: %s"):format(before.by, by, vim.trim(opts.note))
  local res = mutate.edit_text(id, function(current)
    return require("tasks_nvim.steps").add_note(
      current,
      text,
      opts.today or require("tasks_nvim.model").today()
    )
  end, { root = opts.root, today = opts.today, by = by, force = true, note = opts.note })
  return res ~= nil
end

---How a claim reads in one line.
---@param claim Tasks.Claim
---@return string
function M.describe(claim)
  return ("%s since %s until %s"):format(claim.by, claim.since, claim.until_)
end

return M
