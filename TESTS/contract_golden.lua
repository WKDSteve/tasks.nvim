-- TESTS/contract_golden.lua -- the golden files of the contract: which documents, how they are asked for, how they
-- are rendered. Shared by the spec (compares) and TESTS/golden/regenerate.lua (writes), so the two cannot drift.

local G = {}

G.dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/golden/tasks-export-1"

---The day the write cases run on (`updated` of a changed task, the date in a finished file's name).
G.today = "2026-01-02"
G.time = "09:30"

---The version tag of a task file of the vault.
---@param root string
---@param id string
---@return string
local function etag(root, id)
  return assert(require("tasks_nvim.scan").find(id, { root = root })).etag
end

---A JSON request text.
---@param value table
---@return string
local function encode(value)
  return vim.json.encode(value)
end

---Two learning paths for the golden cases `paths` and `path`.
---@param root string
local function write_learning_paths(root)
  local dir = root .. "/lib.nvim/ROADMAP/paths"
  vim.fn.mkdir(dir, "p")
  local function put(path, text)
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  put(
    dir .. "/lua-lernen.md",
    table.concat({
      "---",
      "title: Lua lernen",
      "status: doing",
      "areas: [lib.nvim]",
      'icon: "\240\159\166\128"',
      "created: 2026-01-01",
      "updated: 2026-01-05",
      "---",
      "",
      "Plugins schreiben können.",
      "",
      "## Lernpunkte",
      "",
      "- [ ] Lua lernen {#lua}",
      "  - [ ] Syntax {#syntax}",
      "    - [x] [Manual](https://www.lua.org/manual/5.4/)",
      "      > Notiz: Rangfolge von `..` und `^`.",
      "    - [~] Programming in Lua \226\128\147 Grund: nur Kapitel 1",
      "  - [ ] C-Compiler \226\134\146 lib.nvim/c-compiler {#cc}",
      "  - [-] JIT \226\128\147 Grund: nicht nötig",
      "  - [!] Profiler {#prof}",
      "  - [~] Ohne Grund",
      "",
    }, "\n")
  )
  put(
    dir .. "/leer.md",
    "---\ntitle: Leer\nstatus: planning\ncreated: 2026-01-02\nupdated: 2026-01-02\n---\n\nNoch kein Baum.\n"
  )
end

---Three milestones for the golden cases `milestones`, `milestone` and `result-milestone`: one over a plan, a task, a
---finished task and a task of another area with a `due` passed and a history; one of `close: manual` reached by hand;
---one broken (a bad status, a member that exists nowhere).
---@param root string
local function write_milestones(root)
  local dir = root .. "/lib.nvim/ROADMAP/milestones"
  vim.fn.mkdir(dir, "p")
  local function put(path, text)
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  put(
    dir .. "/release-1.md",
    table.concat({
      "---",
      'title: "Release 1"',
      "status: doing",
      "due: 2026-01-01",
      "includes: [lib.nvim/the-plan, lib.nvim/beta, lib.nvim/old-done, cascade.nvim/zeta]",
      "reached: 2025-12-20",
      "created: 2025-12-01",
      "updated: 2025-12-21",
      "---",
      "",
      "Die erste Ausgabe.",
      "",
      "## Verlauf",
      "",
      "- 2025-12-20 reached",
      "- 2025-12-21 opened again: lib.nvim/beta is open",
      "",
    }, "\n")
  )
  put(
    dir .. "/abnahme.md",
    table.concat({
      "---",
      'title: "Abnahme"',
      "status: done",
      "includes: [lib.nvim/old-done]",
      "close: manual",
      "reached: 2026-01-02",
      "created: 2025-12-01",
      "updated: 2026-01-02",
      "---",
      "",
      "## Verlauf",
      "",
      "- 2026-01-02 reached (closed by hand)",
      "",
    }, "\n")
  )
  put(
    dir .. "/kaputt.md",
    table.concat({
      "---",
      'title: "Kaputt"',
      "status: someday",
      "includes: [lib.nvim/nowhere]",
      "---",
      "",
    }, "\n")
  )
end

---A learning path with XP and levels, and the promoted task it names with its own `xp:`, for the golden cases
---`path-xp` and `result-path-xp`.
---@param root string
local function write_xp_path(root)
  local function put(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  put(
    root .. "/lib.nvim/ROADMAP/tasks/c-compiler.md",
    "---\ntitle: C-Compiler\nstatus: open\nxp: 60\npoint: lib.nvim/rust-lernen#cc\n"
      .. "created: 2026-01-01\nupdated: 2026-01-01\n---\n\nThe compiler.\n"
  )
  put(
    root .. "/lib.nvim/ROADMAP/paths/rust-lernen.md",
    table.concat({
      "---",
      "title: Rust lernen",
      "status: doing",
      "created: 2026-01-01",
      "updated: 2026-01-05",
      "---",
      "",
      "## Lernpunkte",
      "",
      "- [ ] Rust lernen {#rust}",
      "  - [x] Das Buch {xp=30} {#book}",
      "  - [~] Rustlings \226\128\147 Grund: nur die Hälfte {xp=20}",
      "  - [ ] C-Compiler \226\134\146 lib.nvim/c-compiler {xp=40} {#cc}",
      "  - [-] Embedded \226\128\147 Grund: nicht nötig {xp=50}",
      "  - [ ] Ohne XP {#plain}",
      "",
      "## Level",
      "",
      "- [x] 30 XP \194\183 Einsteiger \194\183 Badge assets/badges/stern.png \194\183 Belohnung: großes Eis",
      "- [ ] 50 % \194\183 Badge assets/badges/mond.svg \194\183 Belohnung: Kino",
      "- [ ] 100 XP \194\183 Belohnung: ein Buch",
      "- [ ] 20 XP",
      "- [ ] Pfad fertig \194\183 Belohnung: Wochenende am See",
      "",
    }, "\n")
  )
end

---Write the meetings of the golden cases `meetings`, `meeting` and `task-with-meetings` into `root`.
---@param root string
function G.write_meetings(root)
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  local dir = root .. "/lib.nvim/MEETINGS"
  write(
    dir .. "/sync/sync.md",
    table.concat({
      "---",
      'title: "Sync on alpha"',
      "status: planned",
      "date: 2026-01-12",
      'time: "14:00"',
      'end: "15:30"',
      "tz: Europe/Vienna",
      "location: Room 3",
      "online: https://teams.microsoft.com/l/meetup-join/abc",
      "tasks: [lib.nvim/alpha, lib.nvim/beta]",
      "notify: [-15m, -1d@18:00]",
      "notify_to: [me@example.org]",
      "image: assets/images/cover.png",
      "icon: handshake",
      "tags: [sync]",
      "created: 2026-01-02",
      "---",
      "",
      "Where alpha stands.",
      "",
      "## Agenda",
      "- [x] State",
      "- [ ] Next steps",
      "",
      "## Teilnehmer",
      "- [x] Rick <rick@example.org> (Organisator)",
      "- [ ] Stefan (Ich)",
      "",
      "## Unterlagen",
      "- [Slides](assets/slides.pdf)",
      "- https://example.org/wiki",
      "",
      "## Folgeaufgaben",
      "- [ ] Write it down -> lib.nvim/gamma",
      "- [x] Ask Rick",
      "",
    }, "\n")
  )
  write(dir .. "/sync/assets/images/cover.png", "png")
  write(
    dir .. "/kickoff.md",
    "---\ntitle: Kickoff\nstatus: done\ndate: 2026-01-05\nduration: 48h\ntasks: [lib.nvim/alpha]\n"
      .. "icon: handshake\n---\n\nThe start.\n\n## Ergebnis\nAgreed.\n"
  )
  write(
    dir .. "/old-word.md",
    "---\ntitle: Broken\nstatus: held\ndate: 2026-01-20\n---\n\nOld word.\n"
  )
  write(dir .. "/someday.md", "---\ntitle: Someday\nstatus: planned\n---\n\nNo date yet.\n")
end

---Write a weekly series with an excepted day, an end and one occurrence that has its file (moved by a day) into
---`root`: the golden cases `meetings-series`, `meeting-occurrence` and `result-meeting-series`.
---@param root string
function G.write_series(root)
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  local dir = root .. "/lib.nvim/MEETINGS"
  write(
    dir .. "/one-on-one.md",
    table.concat({
      "---",
      'title: "1:1 Rick"',
      "status: planned",
      "date: 2026-01-05",
      'time: "10:00"',
      "duration: 30m",
      "tasks: [lib.nvim/alpha]",
      "repeat: weekly",
      "repeat_until: 2026-02-02",
      "except: [2026-01-19]",
      "created: 2026-01-02",
      "---",
      "",
      "## Agenda",
      "- [ ] Blockers",
      "",
      "## Protokoll",
      "",
    }, "\n")
  )
  write(
    dir .. "/one-on-one-2026-01-12.md",
    table.concat({
      "---",
      'title: "1:1 Rick"',
      "status: done",
      "date: 2026-01-13",
      'time: "10:00"',
      "duration: 30m",
      "tasks: [lib.nvim/alpha]",
      "series: lib.nvim/one-on-one",
      "created: 2026-01-12",
      "---",
      "",
      "## Ergebnis",
      "Agreed.",
      "",
    }, "\n")
  )
end

---Each case: the file name (without `.json`), the method and the request text (`nil`: no request; a function builds it
---from the vault it runs on). `fresh`: the case WRITES, so it runs on a vault of its own and cannot change what the
---other cases see.
---@type { name: string, method: string, request: string|(fun(root: string): string)|nil, fresh: boolean|nil }[]
G.cases = {
  { name = "hello", method = "hello" },
  { name = "snapshot", method = "snapshot" },
  { name = "list-page", method = "list", request = '{"params":{"limit":5,"offset":0}}' },
  { name = "order-roi", method = "order", request = '{"params":{"sort":"roi"}}' },
  { name = "lists-builtin", method = "lists" },
  { name = "groupings", method = "groupings" },
  { name = "views", method = "views" },
  { name = "task-alpha", method = "task", request = '{"params":{"id":"lib.nvim/alpha"}}' },
  {
    -- a task whose hard blocker is due after it starts and whose soft one is not (capability `late_blockers`)
    name = "task-late-blocker",
    method = "task",
    fresh = true,
    request = function(root)
      local function write(slug, extra)
        local path = root .. "/lib.nvim/ROADMAP/tasks/" .. slug .. ".md"
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local fh = assert(io.open(path, "wb"))
        fh:write(
          ("---\ntitle: %s\nstatus: open\n%screated: 2026-01-01\nupdated: 2026-01-01\n---\n\nLate.\n"):format(
            slug,
            extra
          )
        )
        fh:close()
      end
      write("late-blocker", "due: 2026-03-10\n")
      write("early-blocker", "due: 2026-02-20\n")
      write(
        "waits-on-late",
        "start: 2026-03-01\ndue: 2026-03-20\nblocked_by: [lib.nvim/late-blocker]\nafter: [lib.nvim/early-blocker]\n"
      )
      return '{"params":{"id":"lib.nvim/waits-on-late"}}'
    end,
  },
  {
    -- a routine with its finished rounds (capability `rounds`): two earlier rounds of the same stem, newest first; a
    -- finished task of that stem without `repeat` and a routine of another stem are no rounds of it
    name = "task-routine",
    method = "task",
    fresh = true,
    request = function(root)
      local function write(path, text)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local fh = assert(io.open(path, "wb"))
        fh:write(text)
        fh:close()
      end
      local function file(title, status, extra)
        return ("---\ntitle: %s\nstatus: %s\n%screated: 2026-01-01\nupdated: 2026-01-01\n---\n\nA routine.\n"):format(
          title,
          status,
          extra
        )
      end
      write(
        root .. "/lib.nvim/ROADMAP/tasks/backup-check-2026-03-01.md",
        file("Backup check", "open", "repeat: 4w\ndue: 2026-03-01\n")
      )
      write(
        root .. "/lib.nvim/Backlog/TASKS/2026-01-03_backup-check.md",
        file(
          "Backup check",
          "done",
          "repeat: 4w\ndue: 2026-01-01\ndone_in: lib.nvim@aaa1111\ncommits: [lib.nvim@aaa1111]\n"
        )
      )
      write(
        root .. "/lib.nvim/Backlog/TASKS/2026-02-02_backup-check-2026-01-31.md",
        file("Backup check", "done", "repeat: 4w\ndue: 2026-01-31\n")
      )
      write(
        root .. "/lib.nvim/Backlog/TASKS/2026-01-05_backup-check-2026-01-04.md",
        file("Backup check, once", "done", "due: 2026-01-04\n")
      )
      write(
        root .. "/lib.nvim/Backlog/TASKS/2026-01-06_backup-checks.md",
        file("Other routine", "done", "repeat: 1w\ndue: 2026-01-05\n")
      )
      return '{"params":{"id":"lib.nvim/backup-check-2026-03-01"}}'
    end,
  },
  {
    -- a finished task read from its area's Backlog (capability `task_finished`): its commits and done_in, its body,
    -- `finished`, no readiness and no rounds; how it ended and the learning point it came from (capability `outcome`);
    -- the CI state of its commits (capability `ci`)
    name = "task-finished",
    method = "task",
    fresh = true,
    request = function(root)
      local path = root .. "/lib.nvim/Backlog/FEATURES/2026-01-09_shipped.md"
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local fh = assert(io.open(path, "wb"))
      fh:write(
        "---\ntitle: Shipped\nstatus: done\nkind: feature\ndone_in: lib.nvim@bbb2222\n"
          .. "commits: [lib.nvim@bbb2222]\nci: red\noutcome: seen\noutcome_reason: only chapter 1\n"
          .. "point: lib.nvim/lua-path#cc\ncreated: 2026-01-01\nupdated: 2026-01-09\n---\n\n"
          .. "## Akzeptanz\n\n- [x] it ships\n"
      )
      fh:close()
      return '{"params":{"id":"lib.nvim/shipped","finished":true}}'
    end,
  },
  {
    -- the open learning paths with their progress (capability `paths`): one with a tree of every state, a promoted
    -- point, a note and an image; one without a tree
    name = "paths",
    method = "paths",
    fresh = true,
    request = function(root)
      write_learning_paths(root)
      return '{"params":{}}'
    end,
  },
  {
    -- one learning path with its tree as a flat list (capability `path`): states, the derived state of a parent,
    -- progress per point, key, reason, arrow, link, image, note, and the problems of the tree
    name = "path",
    method = "path",
    fresh = true,
    request = function(root)
      write_learning_paths(root)
      return '{"params":{"id":"lib.nvim/lua-lernen"}}'
    end,
  },
  {
    -- the milestones with their progress (capability `milestones`): a plan counted by its tasks, a finished task, a
    -- passed `due` (overdue), one reached by hand (`close: manual`), one broken
    name = "milestones",
    method = "milestones",
    fresh = true,
    request = function(root)
      write_milestones(root)
      return '{"params":{}}'
    end,
  },
  {
    -- one milestone with its members (kind, state, what each counts), its history and its body (capability
    -- `milestone`)
    name = "milestone",
    method = "milestone",
    fresh = true,
    request = function(root)
      write_milestones(root)
      return '{"params":{"id":"lib.nvim/release-1"}}'
    end,
  },
  {
    -- writing milestones (capabilities `milestone_new`, `milestone_set`): one made over a finished task is reached
    -- at once (`milestones_reached`), one refused for a member that exists nowhere, a `status: done` by hand refused
    -- while a member is open (`details.holding`), a change with its inverse
    name = "result-milestone",
    method = "ops",
    fresh = true,
    request = function(root)
      write_milestones(root)
      return encode({
        client_op_id = "golden-milestone",
        ops = {
          {
            op = "milestone_new",
            area = "cascade.nvim",
            title = "Altlast",
            due = "2026-02-01",
            includes = { "lib.nvim/old-done" },
          },
          {
            op = "milestone_new",
            area = "cascade.nvim",
            title = "Nirgends",
            includes = { "lib.nvim/nowhere" },
          },
          { op = "milestone_set", id = "lib.nvim/release-1", patch = { status = "done" } },
          { op = "milestone_set", id = "lib.nvim/release-1", patch = { due = "2026-03-01" } },
          -- reached at once by op 1: kept open by hand only with close: manual (details.hint)
          { op = "milestone_set", id = "cascade.nvim/altlast", patch = { status = "doing" } },
        },
      })
    end,
  },
  {
    -- XP and levels of a path (capability `xp`): the XP of a promoted task win over the point's, seen counts half,
    -- dropped not at all, a leaf without XP gets a suggestion; the levels with the one reached, the next with the XP
    -- missing, the rewards not granted yet, and a threshold that does not rise
    name = "path-xp",
    method = "path",
    fresh = true,
    request = function(root)
      write_xp_path(root)
      return '{"params":{"id":"lib.nvim/rust-lernen"}}'
    end,
  },
  {
    -- the XP of a point and the reward of a level written (capabilities `xp`, `path_reward`), each with its inverse;
    -- a level without a reward and both xp and xp_clear refused; the levels written (`path_levels`) and a bad one refused
    name = "result-path-xp",
    method = "ops",
    fresh = true,
    request = function(root)
      write_xp_path(root)
      local P = "lib.nvim/rust-lernen"
      return encode({
        client_op_id = "golden-path-xp",
        ops = {
          { op = "node_set", id = P, point = "plain", xp = 15 },
          { op = "node_set", id = P, point = "book", xp_clear = true },
          { op = "path_reward", id = P, level = "2", given = true },
          { op = "path_reward", id = P, level = "4", given = true },
          { op = "node_set", id = P, point = "plain", xp = 5, xp_clear = true },
          -- the levels written as a whole (capability `path_levels`), with the levels they had as the inverse
          {
            op = "path_levels",
            id = P,
            levels = {
              list = {
                { threshold = 10, unit = "xp", name = "Start", reward = "Tee" },
                { threshold = 60, unit = "percent", badge = "assets/badges/star.svg" },
              },
              done = { reward = "Kino" },
            },
          },
          { op = "path_levels", id = P, levels = { list = { { threshold = 0, unit = "xp" } } } },
          -- the old section had falling thresholds (no inverse above); removing the clean one carries it
          { op = "path_levels", id = P, levels = { list = {} } },
        },
      })
    end,
  },
  {
    -- the meetings of a window (capability `meetings`): one with time, address, tasks, notifications and a folder,
    -- one all day, one broken (still listed with its problems), one without a date (counted in `undated`)
    name = "meetings",
    method = "meetings",
    fresh = true,
    request = function(root)
      G.write_meetings(root)
      return '{"params":{"since":"2026-01-01","until":"2026-03-31"}}'
    end,
  },
  {
    -- a line of the quick capture read into a proposal (capability `meeting_parse`): a weekday, a time span, a service
    -- word beside an address, a task, a notification and a word that looks like one but is none
    name = "meeting-parse",
    method = "meeting_parse",
    request = '{"params":{"text":"Mo 14:00-15:00 Sync mit Rick @teams https://teams.microsoft.com/l/x #lib.nvim/alpha !-15m !soon"}}',
  },
  {
    -- no day in the line: today, and `assumed` says so; a place with a blank
    name = "meeting-parse-assumed",
    method = "meeting_parse",
    request = '{"params":{"text":"Workshop 9:30 90m @Raum_3.14"}}',
  },
  {
    -- one meeting with its body and the sections the engine reads (capability `meeting`)
    name = "meeting",
    method = "meeting",
    fresh = true,
    request = function(root)
      G.write_meetings(root)
      return '{"params":{"id":"lib.nvim/sync"}}'
    end,
  },
  {
    -- a series in a window (capability `meeting_series`): its occurrences computed (`virtual`), one with a file in place
    -- of its day (moved a day), the excepted day and the days after `repeat_until` left out
    name = "meetings-series",
    method = "meetings",
    fresh = true,
    request = function(root)
      G.write_series(root)
      return '{"params":{"since":"2026-01-01","until":"2026-02-28"}}'
    end,
  },
  {
    -- an occurrence of a series without a file, read by its id (`<slug of the series>-<day>`)
    name = "meeting-occurrence",
    method = "meeting",
    fresh = true,
    request = function(root)
      G.write_series(root)
      return '{"params":{"id":"lib.nvim/one-on-one-2026-01-26"}}'
    end,
  },
  {
    -- a task entry with the meetings that name it (`meetings`, the earliest first)
    name = "task-with-meetings",
    method = "task",
    fresh = true,
    request = function(root)
      G.write_meetings(root)
      return '{"params":{"id":"lib.nvim/alpha"}}'
    end,
  },
  {
    -- the answer of a review job taken apart (capability `agent_answer`): its section and the follow-up it proposes
    name = "agent-answer-review",
    method = "agent_answer",
    request = vim.json.encode({
      params = {
        kind = "review-done",
        id = "lib.nvim/alpha",
        output = "Checked.\n\n<!-- review:begin -->\n## Prüfung\n\n- [x] it is done — erfüllt: a.lua:1\n"
          .. "- [ ] documented — offen\n\n### Folgetask (Vorschlag)\n\n- title: Document it\n"
          .. "- summary: The README names it.\n<!-- review:end -->\n",
      },
    }),
  },
  { name = "bodies-page", method = "bodies", request = '{"params":{"limit":3,"offset":1}}' },
  {
    name = "estimate",
    method = "estimate",
    request = '{"params":{"ids":["lib.nvim/alpha","lib.nvim/beta","lib.nvim/gamma"],"assume":[{"id":"lib.nvim/alpha","effort":"M","value":4}]}}',
  },
  -- the open plans side by side: the plan of the fixture with a finished member, its pace over the last weeks
  { name = "plancompare", method = "plan_compare" },
  { name = "planfor", method = "plan_for", request = '{"params":{"id":"cascade.nvim/iota"}}' },
  { name = "check", method = "check", request = '{"params":{"area":"lib.nvim"}}' },
  { name = "next", method = "next", request = '{"params":{"n":3}}' },
  {
    name = "next-not-category",
    method = "next",
    request = '{"params":{"n":3,"not_category":["learning"]}}',
  },
  { name = "areas", method = "areas" },
  { name = "waits", method = "waits" },
  {
    name = "find",
    method = "find",
    request = '{"params":{"refs":["docs/shared.md","lib.nvim@abc1234","testing-finding:0123456789abcdef"]}}',
  },
  {
    name = "intent-would-create",
    method = "intent",
    request = '{"params":{"intent":{"schema":"wkd-intent/1","action":"tasks.new","mode":"form","source":{"app":"testing","finding":"0123456789abcdef"},"finding":{"schema":"testing-finding/1","fp":"0123456789abcdef","class":"public","area":"lib.nvim","title":"parse_spec: an empty line ends the list","excerpt":"expected 2 items, got 1","repro":"scripts/test.sh --file parse_spec","where":{"file":"TESTS/parse_spec.lua","line":12}},"target":null}}}',
  },
  { name = "list-waits-for", method = "list", request = '{"params":{"waits_for":["mac"]}}' },
  { name = "links", method = "links" },
  { name = "finished", method = "finished", request = '{"params":{"limit":3}}' },
  {
    name = "finished-plan",
    method = "finished",
    request = '{"params":{"plan":"lib.nvim/the-plan"}}',
  },
  {
    name = "finished-window",
    method = "finished",
    request = '{"params":{"since":"2025-12-31","until":"2026-01-01"}}',
  },
  -- the finished tasks by the CI state of their commits (capability `finished_ci`): the shipped bug says green
  {
    name = "finished-ci",
    method = "finished",
    request = '{"params":{"ci":["green","red"]}}',
  },
  -- the series of the figures: a window around the rows of the fixture (a day before the first row, a carried day,
  -- a line that is no row), and the same by week for one area
  {
    name = "history",
    method = "history",
    request = '{"params":{"since":"2025-12-29","until":"2026-01-02"}}',
  },
  {
    name = "history-weeks",
    method = "history",
    request = '{"params":{"area":"lib.nvim","since":"2025-12-22","until":"2026-01-04","resolution":"week"}}',
  },
  { name = "error-unsupported-schema", method = "list", request = '{"schema":2}' },
  { name = "error-unknown-parameter", method = "list", request = '{"params":{"colour":"red"}}' },
  { name = "donepreview", method = "done_preview", request = '{"params":{"id":"lib.nvim/delta"}}' },
  {
    -- a ladder (capability `repeat_steps`): the open round carries `repeat` as a ladder, its `repeat_step` and what
    -- the routine started after; the preview of its last round says that the finish ends the routine
    name = "donepreview-ladder-last",
    method = "done_preview",
    fresh = true,
    request = function(root)
      local path = root .. "/lib.nvim/ROADMAP/tasks/review-2026-03-02.md"
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local fh = assert(io.open(path, "wb"))
      fh:write(
        "---\ntitle: Review\nstatus: open\nrepeat: 1w,4w,12w\nrepeat_step: 3\n"
          .. "repeat_after: lib.nvim/alpha\ndue: 2026-03-02\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nAgain.\n"
      )
      fh:close()
      return '{"params":{"id":"lib.nvim/review-2026-03-02"}}'
    end,
  },
  {
    -- the same ladder as a task entry (capability `repeat_steps`)
    name = "task-ladder",
    method = "task",
    fresh = true,
    request = function(root)
      local path = root .. "/lib.nvim/ROADMAP/tasks/review-2026-03-02.md"
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local fh = assert(io.open(path, "wb"))
      fh:write(
        "---\ntitle: Review\nstatus: open\nrepeat: 1w,4w,12w\nrepeat_step: 2\n"
          .. "repeat_after: lib.nvim/alpha#lua\ndue: 2026-03-02\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nAgain.\n"
      )
      fh:close()
      return '{"params":{"id":"lib.nvim/review-2026-03-02"}}'
    end,
  },
  {
    -- a finish that starts a routine waiting for it (`repeat_after`, capability `repeat_steps`): `routines_started`
    -- names it with its first due date, `changed_ids` carries it
    name = "result-routine-started",
    method = "ops",
    fresh = true,
    request = function(root)
      local mutate = require("tasks_nvim.mutate")
      local path = root .. "/lib.nvim/ROADMAP/tasks/delta-review.md"
      local fh = assert(io.open(path, "wb"))
      fh:write(
        "---\ntitle: Delta review\nstatus: open\nrepeat: 1w,4w,12w\nrepeat_after: lib.nvim/delta\n"
          .. "created: 2026-01-01\nupdated: 2026-01-01\n---\n\nAfter delta.\n"
      )
      fh:close()
      return encode({
        client_op_id = "golden-routine-started",
        ops = {
          {
            op = "done",
            id = "lib.nvim/delta",
            confirm = mutate.confirm_token("lib.nvim/delta", etag(root, "lib.nvim/delta")),
          },
        },
      })
    end,
  },
  {
    -- every operation as a dry run: nothing is written, the answer says what would happen
    name = "result-dry-run",
    method = "ops",
    request = function(root)
      return encode({
        client_op_id = "golden-dry",
        dry_run = true,
        ops = {
          {
            op = "set",
            id = "cascade.nvim/eta",
            patch = { summary = "Golden summary", tags = { "golden" } },
            if_match = etag(root, "cascade.nvim/eta"),
          },
          { op = "new", area = "cascade.nvim", title = "Golden new task", fields = { prio = 2 } },
          { op = "reorder", id = "lib.nvim/alpha-twin", before = "lib.nvim/alpha" },
          { op = "done", id = "lib.nvim/delta" },
          { op = "answer", id = "lib.nvim/alpha", question = "q1", option = 1 },
          { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" },
          {
            op = "plan_new",
            area = "lib.nvim",
            title = "Golden plan",
            phases = { "design", "build" },
          },
          { op = "history_record" },
        },
      })
    end,
  },
  {
    -- `new` with its relations: made with after, plan and phase; each relation that is wrong refused, nothing written
    name = "result-new-relations",
    method = "ops",
    fresh = true,
    request = function()
      local function new(title, fields)
        return { op = "new", area = "cascade.nvim", title = title, fields = fields }
      end
      return encode({
        client_op_id = "golden-new-relations",
        ops = {
          new(
            "Golden related task",
            { after = { "lib.nvim/alpha" }, plan = "lib.nvim/the-plan", phase = "test" }
          ),
          new("Golden dangling after", { after = { "lib.nvim/nowhere" } }),
          new("Golden unknown plan", { plan = "lib.nvim/no-plan" }),
          new("Golden unknown phase", { plan = "lib.nvim/the-plan", phase = "deploy" }),
          -- a phase that is no kebab-case word: the details name the character and a word that would do
          new("Golden umlaut phase", { phase = "einführung" }),
        },
      })
    end,
  },
  {
    -- projects through the door: made, a stage changed (with its inverse), refused changes, a gate, a task of the
    -- project itself, and a close that something holds open
    name = "result-projects",
    method = "ops",
    fresh = true,
    request = function()
      return encode({
        client_op_id = "golden-projects",
        ops = {
          {
            op = "project_new",
            area = "lib.nvim",
            title = "Golden project",
            phases = { "first", "second" },
            links = { "https://example.org/golden" },
          },
          {
            op = "plan_set",
            id = "lib.nvim/the-plan",
            patch = { phase = "second" },
          },
          { op = "plan_set", id = "lib.nvim/the-plan", patch = { phase = "nope" } },
          {
            op = "project_new",
            area = "lib.nvim",
            title = "Golden umlaut project",
            phases = { "testen", "einführung" },
          },
          { op = "project_set", id = "lib.nvim/the-project", patch = { gate = "hard" } },
          { op = "plan_close", id = "lib.nvim/the-plan" },
          {
            op = "new",
            area = "cascade.nvim",
            title = "Golden project task",
            fields = { project = "lib.nvim/the-project", phase = "second" },
          },
        },
      })
    end,
  },
  {
    -- `add_steps` for real: appended below the last step of a plan, a section made for a task without one, a step that
    -- is a list line refused (nothing written)
    name = "result-add-steps",
    method = "ops",
    fresh = true,
    request = function(root)
      return encode({
        client_op_id = "golden-add-steps",
        ops = {
          {
            op = "add_steps",
            id = "lib.nvim/alpha",
            steps = { "fourth -- Akzeptanz 1", "fifth" },
            if_match = etag(root, "lib.nvim/alpha"),
          },
          { op = "add_steps", id = "lib.nvim/beta", steps = "only step" },
          { op = "add_steps", id = "lib.nvim/gamma", steps = { "- [ ] a list line" } },
        },
      })
    end,
  },
  {
    -- `set_section` for real: a section added at the end (no inverse), then replaced (its inverse sets the old text)
    name = "result-set-section",
    method = "ops",
    fresh = true,
    request = function()
      return encode({
        client_op_id = "golden-set-section",
        ops = {
          {
            op = "set_section",
            id = "lib.nvim/alpha",
            heading = "## Prüfung",
            text = "- [x] first",
          },
          {
            op = "set_section",
            id = "lib.nvim/alpha",
            heading = "## Prüfung",
            text = "- [x] second",
          },
        },
      })
    end,
  },
  {
    -- meetings for real: made, a capture of each kind that has a section, a participant present, a follow-up made a
    -- task, closed with a result; a capture without text refused
    name = "result-meetings",
    method = "ops",
    fresh = true,
    request = function()
      local id = "lib.nvim/sync-2026-10-20"
      return encode({
        client_op_id = "golden-meetings",
        ops = {
          {
            op = "meeting_new",
            area = "lib.nvim",
            title = "Sync",
            fields = { date = "2026-10-20", time = "14:00", duration = "45m" },
            body = "## Teilnehmer\n\n- [ ] Rick (Organisator)",
          },
          {
            op = "meeting_capture",
            id = id,
            entry = { kind = "task", text = "Lizenz klären", at = "14:05" },
          },
          {
            op = "meeting_capture",
            id = id,
            entry = { kind = "decision", text = "Start Dezember", at = "14:06" },
          },
          { op = "meeting_capture", id = id, entry = { kind = "text", at = "14:07" } },
          { op = "meeting_attend", id = id, n = 1 },
          { op = "meeting_followups", id = id },
          { op = "meeting_close", id = id, result = "Vereinbart." },
        },
      })
    end,
  },
  {
    -- the first entry into an occurrence of a series makes its file (`created`); a cancellation is an entry too; a
    -- change that changes nothing leaves it computed
    name = "result-meeting-series",
    method = "ops",
    fresh = true,
    request = function(root)
      G.write_series(root)
      return encode({
        client_op_id = "golden-meeting-series",
        ops = {
          {
            op = "meeting_capture",
            id = "lib.nvim/one-on-one-2026-01-05",
            entry = { kind = "decision", text = "Ship it", at = "10:10" },
          },
          {
            op = "meeting_set",
            id = "lib.nvim/one-on-one-2026-01-26",
            patch = { status = "cancelled" },
          },
          {
            op = "meeting_set",
            id = "lib.nvim/one-on-one-2026-02-02",
            patch = { status = "planned" },
          },
        },
      })
    end,
  },
  {
    -- saved views for real: made, replaced on the version read, replaced on a stale one, deleted, a view that is not there
    name = "result-views",
    method = "ops",
    fresh = true,
    request = function(root)
      local views = require("tasks_nvim.views")
      local function view_etag(id)
        local area, slug = id:match("^([^/]+)/(.+)$")
        return require("tasks_nvim.fsio").etag(
          assert(require("tasks_nvim.fsio").read(views.path(root, area, slug)))
        )
      end
      return encode({
        client_op_id = "golden-views",
        ops = {
          {
            op = "view_save",
            area = "cascade.nvim",
            view = {
              title = "Golden view",
              display = "list",
              group_by = "kind",
              select = { actors = { "me" } },
            },
          },
          {
            op = "view_save",
            id = "lib.nvim/by-status",
            view = {
              title = "Columns by status",
              display = "columns",
              group_by = "status",
              collapsed = { "parked" },
            },
            if_match = view_etag("lib.nvim/by-status"),
          },
          {
            op = "view_save",
            id = "lib.nvim/by-status",
            view = { title = "Stale", display = "list", group_by = "status" },
            if_match = "sha256:0000000000000000",
          },
          {
            op = "view_delete",
            id = "lib.nvim/prio-by-actor",
            if_match = view_etag("lib.nvim/prio-by-actor"),
          },
          { op = "view_delete", id = "lib.nvim/not-there", if_match = "sha256:0000000000000000" },
        },
      })
    end,
  },
  {
    -- the same kinds of operations for real, on a vault of their own, with the failures a client has to handle
    name = "result-run",
    method = "ops",
    fresh = true,
    request = function(root)
      local mutate = require("tasks_nvim.mutate")
      return encode({
        client_op_id = "golden-run",
        ops = {
          {
            op = "set",
            id = "cascade.nvim/eta",
            patch = { summary = "Golden summary", tags = { "golden" } },
            if_match = etag(root, "cascade.nvim/eta"),
          },
          {
            op = "set",
            id = "lib.nvim/gamma",
            patch = { prio = 1 },
            if_match = "sha256:0000000000000000",
          },
          { op = "new", area = "cascade.nvim", title = "Golden new task", fields = { prio = 2 } },
          { op = "reorder", id = "lib.nvim/alpha-twin", before = "lib.nvim/alpha" },
          {
            op = "done",
            id = "lib.nvim/delta",
            confirm = mutate.confirm_token("lib.nvim/delta", etag(root, "lib.nvim/delta")),
          },
          { op = "set", id = "lib.nvim/alpha", patch = { blocked_by = { "lib.nvim/beta" } } },
          { op = "move_area", id = "lib.nvim/alpha", to_area = "cascade.nvim" },
        },
      })
    end,
  },
}

---The variables besides `TASKS_*` the engine reads that name this machine's setup or session.
G.MACHINE_VARS = { NVIM_CONFIG_DIR = true, CLAUDE_CODE_SESSION_ID = true }

---Run `fn` with the clock and the engine info fixed, then put them back.
---@generic T
---@param fn fun(): T
---@return T
function G.fixed(fn)
  local contract = require("tasks_nvim.contract")
  local clock, engine = contract.clock, contract.engine_info
  -- The named lists of this machine are not part of a golden: no state file, none of the configuration.
  local lists, config = require("tasks_nvim.lists"), require("tasks_nvim.config")
  local lists_path, lists_cfg = lists.path(), config.get().lists or {}
  lists.set_path(vim.fn.tempname() .. "/none/lists.json")
  config.merge({ lists = {} })
  -- Nor the variables that point the engine at this machine's data or setup (`$TASKS_MARKER_DOCS` names documents
  -- of the real vault, and a note about one put a path of this machine into result-run.json): every `TASKS_*`
  -- and the few others the engine reads are gone while a golden is made, and back afterwards.
  local env = {}
  for name, value in pairs(vim.fn.environ()) do
    local upper = name:upper()
    if upper:match("^TASKS_") or G.MACHINE_VARS[upper] then
      env[name] = value
      vim.env[name] = nil
    end
  end
  contract.clock = function()
    return "2026-01-01T00:00:00Z"
  end
  contract.engine_info = function()
    return { version = "0.1.0-test", git = "0000000", nvim = "0.0.0" }
  end
  local ok, res = pcall(fn)
  for name, value in pairs(env) do
    vim.env[name] = value
  end
  contract.clock, contract.engine_info = clock, engine
  lists.set_path(lists_path)
  config.merge({ lists = lists_cfg })
  if not ok then
    error(res, 0)
  end
  return res
end

---The readable canonical text of one case.
---@param root string
---@param case { method: string, request: string|(fun(root: string): string)|nil, fresh: boolean|nil }
---@param build? fun(): string  # Makes a vault of its own, for a case that writes.
---@return string
function G.render(root, case, build)
  if case.fresh then
    assert(build, "the case " .. tostring(case.method) .. " writes: it needs a vault of its own")
    root = build()
  end
  local request = case.request
  if type(request) == "function" then
    request = request(root)
  end
  return G.fixed(function()
    local text = require("tasks_nvim.api").call(
      case.method,
      request,
      { root = root, indent = 2, today = G.today, time = G.time }
    )
    return text .. "\n"
  end)
end

---@param name string
---@return { name: string, method: string, request: string|nil }
function G.case(name)
  for _, c in ipairs(G.cases) do
    if c.name == name then
      return c
    end
  end
  error("no golden case " .. name)
end

return G
