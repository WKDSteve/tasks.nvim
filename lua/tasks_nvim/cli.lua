---@module 'tasks_nvim.cli'
-- @scans-data: the folders it lists and the paths it names are task vaults, never the files of this plugin
---@brief Command-line front end of the task engine: `list`, `index`, `new`, `set`, `done`, `attach`, `folderize`, `check`, `template`, `areas`, `export`, `waits`, `release`.
---@description
--- `run(argv, io)` parses one command line, calls the engine and prints plain,
--- tab-separated lines; it returns the exit code and never raises. The
--- headless entry `scripts/tasks.lua` is a three-line wrapper around it, so a
--- Claude session without a running Neovim creates and finishes tasks the same
--- way the editor commands will (rule R12).
---
--- Exit codes: 0 success; 1 a finding, a stale index in `--check`, or a failed
--- operation; 2 a usage error.
---
--- Key responsibilities:
---  - argument parsing (`--key=value`, `--flag`, `key=value` for `set`) with
---    unknown options reported instead of ignored
---  - one function per subcommand, each a thin call into `vault`/`scan`/`index`/
---    `mutate`/`check`
---
--- Not its job: any logic of its own about tasks. If something here grows a
--- rule, it belongs in the engine module it calls.

local check = require("tasks_nvim.check")
local contract = require("tasks_nvim.contract")
local history = require("tasks_nvim.history")
local index = require("tasks_nvim.index")
local model = require("tasks_nvim.model")
local done_flow = require("tasks_nvim.done_flow")
local estimate = require("tasks_nvim.estimate")
local contract_cli = require("tasks_nvim.cli_contract")
---@type Tasks.CliContractHelpers
local contract_helpers = {}
local lists = require("tasks_nvim.lists")
local quick_wins = require("tasks_nvim.quick_wins")
local fsio = require("tasks_nvim.fsio")
local agent_brief = require("tasks_nvim.agent_brief")
local mutate = require("tasks_nvim.mutate")
local questions = require("tasks_nvim.questions")
local next_pick = require("tasks_nvim.next_pick")
local plan_scope = require("tasks_nvim.plan_scope")
local claims = require("tasks_nvim.claims")
local plan_view = require("tasks_nvim.plan_view")
local scan = require("tasks_nvim.scan")
local staleness = require("tasks_nvim.staleness")
local vault = require("tasks_nvim.vault")
local waits = require("tasks_nvim.waits")

local M = {}

---@class Tasks.CliIO
---@field out fun(text: string)   # Written verbatim (callers add the newline).
---@field err fun(text: string)
---@field stdin? file*   # Where `-` reads from (default `io.stdin`).

---@type Tasks.CliIO
M.stdio = {
  out = function(text)
    io.stdout:write(text)
  end,
  err = function(text)
    io.stderr:write(text)
  end,
}

local USAGE = [[
usage: nvim --headless -u NONE -l scripts/tasks.lua <command> [args]

commands:
  list [<area>] [--status=a,b] [--prio=1,2|<=2] [--effort=S,M|<=M] [--kind=k] [--tag=t]
       [--category=c,d] [--severity=high,critical] [--value=4,5|>=4] [--actor=cdx,me,pair,none]
       [--waits-for=key,key|none] [--outcome=learned,seen,not-applicable|none] [--ci=pending,green,red|none]
       [--stale=<days>|refs] [--stale-refs] [--blocked] [--reminders] [--ready|--waiting] [--unestimated] [--quick-win]
       [--overdue] [--due-before=YYYY-MM-DD] [--starts-after=YYYY-MM-DD]
       [--sheet=red,stale,never,inbox,manual,green,unknown|any|none]
       [--claimed=own,foreign,none]
       [--sort=default|prio-effort|severity|frecency|roi|due|created-desc|created-asc|updated-desc|updated-asc|remind|title]
       [--format=tsv|ids|json] [--done]   open tasks, sorted; one line each
       (--format=json: the tasks.list document in plan order or that of --sort, with [--limit=1..100] [--offset=N]; --done: the finished tasks)
       (categories: @CATEGORIES@; --category=bug also finds kind=bug;
        --sort=prio-effort: small first within a prio; --sort=severity: critical first;
        --sort=roi: most value per effort first, tasks without value or effort last;
        --sort=created-desc|created-asc|updated-desc|updated-asc: by that date, a task without it last either way;
        --sort=remind: next reminder first, without one last; --sort=title: alphabetical, regardless of case;
        --actor=me also finds status=decision and the tag needs-user; none = nobody classified it;
        --sort=frecency: what the dashboard opened or changed most, from the frecency file;
        --waits-for: the parked tasks that wait for one of these keys (`waits_for:`), none = parked without a reason)
       (--ready: nothing open blocks it; --waiting: an open blocker; --unestimated: no effort or no value;
        --quick-win: value and effort at the quick-win thresholds, see `quickwins`;
        --reminders: a reminder (`remind:`) that is due, its date is today or earlier;
        --overdue / --due-before=<day>: the `due:` date is before today / before that day; --starts-after=<day>: the
        `start:` date is after it; a task without the date never matches; --sort=due: earliest due first, undated last;
        --sheet: the state of the test-sheet block testing.nvim wrote into the task, its worst sheet (inbox:
        green and waiting for your judgement), any: a task with the block, none: a task without it; nothing is run;
        --claimed: own: a valid claim of this name (`claim`), foreign: of somebody else, none: free or expired)
  plan-new <area> <title> [--slug=s] [--areas=a,b] [--target=<id>] [--phases=a,b,c] [--gate=hard] [--summary=text] [--links=url,url] [--icon=<emoji|assets/x.svg|word>] [--cover=assets/x.png] [--template=learning]
                                          create ROADMAP/plans/<slug>.md; tasks join it with plan=<id> phase=<word>;
                                          without --slug the slug is the title, cut at a word boundary
  project-new <area> <title> [--slug=s] [options as plan-new] [--requires=id,id] [--requires-gate=soft|hard]
                                          create ROADMAP/projects/<slug>.md; plans join it with project=<id>, learning
                                          paths with path-new --project=<id>; --requires names the learning paths
                                          and projects it builds on (gate soft: a note; hard: not finished before
                                          them; set later with set <id> "requires=[a/b,c/d]"); --template=learning writes a
                                          curriculum: goal and competence target, ## Lernpfade with the generated
                                          table of its paths (refreshed by projects --of=<id> --write=<file>), ## Takt,
                                          definition of done (no stages are proposed)
  path-new <area> <title> [--slug=s] [--areas=a,b] [--target=<id>] [--project=<id>] [--requires=id,id] [--requires-gate=soft|hard] [--tags=a,b] [--status=planning|doing|parked] [--summary=text] [--links=url,url] [--icon=...] [--cover=assets/x.png] [--template=learning] [--no-index] [--dry-run]
                                          create the learning path ROADMAP/paths/<slug>.md (no stages; its tree goes
                                          into ## Lernpunkte); --template=learning writes the sections of a learning path;
                                          --tags=not-on-workstation (or on-workstation) goes to every task promoted
                                          from the path; --requires as project-new; --no-index is accepted (a new
                                          path changes no index)
  path-new <area> --from=<draft.md> [--slug=s] [--dry-run]
                                          the whole path from a draft file: checked as check checks a path (keys,
                                          marks, XP, arrows, links, levels, images), written only when nothing is
                                          wrong; every finding names the draft's line and its code (exit 1, nothing
                                          written); --dry-run says what would be made and writes nothing
  path <area>/<slug> [--machine=private|workstation|wsl|env|all] [--format=text|json]  the XP overview of a learning path: points (all, open, without XP), XP in
                                          all and per stage (a root of ## Lernpunkte), and for each level the point
                                          at which it is reached when the points are learned in their order; the
                                          optional points ({optional} on a node) apart: they count for no level in
                                          percent and not for the path being done, their XP once earned do
                                          {safety} points come first (`safety` lines); --machine lists only the open
                                          points that may be practised on that machine (`todo`) and says how many
                                          are hidden (`hidden`); `env` reads NVIM_MACHINE_ROLE (empty/default: private); without --machine the text output filters by that role (--machine=all shows every point; JSON stays whole)
  point <area>/<slug> <key|#n> --state=open|learned|seen|dropped|blocked [--reason=text] [--ack]
                                          change one learning point of a path (the operation node_set); seen and
                                          dropped need a reason; closing (learned, seen) a point on or under a
                                          {safety} mark needs --ack: you read it
  path <area>/<slug> --schedule [--write]
                                          the table of ## Zeitplan made from the tree: each point with planned hours
                                          ({h=8} or {h=8-10}; {done_h=9} the hours it took), its result (the child
                                          Nachweis:/Aufgabe:/Ergebnis:) and its state; --write puts it into the file
                                          between <!-- GENERATED:schedule start/end --> (a hand-kept table gives way)
  learn next [<area>] [--machine=private|workstation|wsl|env|all] [--n=N] [--paths=id,id] [--format=tsv|json]
                                          the next points of the running learning paths (status doing or a point
                                          learned or seen; an idle one of a project with status doing too): per
                                          path the first N (3) open points in their order that are not blocked, not
                                          optional and, with --machine, may be practised there; a line per point
                                          (path, #key, stage, label, safety)
  learn notes [<text>] [--kind=note|link|image] [--area=a,b] [--paths=id,id] [--done] [--limit=N] [--format=tsv|json]
                                          the notes, links and images of the learning points of all paths, those
                                          whose label, note or link contain <text> (any case); --done adds the
                                          finished paths; a line per point (path, #key, state, label, note or link)
  learn evidence [<area>] [--competence=<id>] [--paths=id,id] [--done] [--format=tsv|json]
                                          the evidence of the learning paths: points whose label starts with
                                          Nachweis:, Aufgabe: or Ergebnis: ({for=t4}: the stage it proves); --done
                                          adds the finished paths; a line per point (path, #key, state, stage, label,
                                          link)
  learn history [<area>] [--since=YYYY-MM-DD] [--until=YYYY-MM-DD] [--step=day|week|month] [--paths=id,id] [--format=tsv|json]
                                          what the series of the learning figures says (written by history record
                                          and index into _Telemetry/history/learn-YYYY-MM.jsonl, from its first day
                                          on): per step points learned, seen, dropped, XP, hours and learning days,
                                          and the streak of learning days; --format=json adds per path the day each
                                          level was reached and each reward granted, the pace and the forecast
  competences [<area>] [--format=tsv|json]
                                          the competences (<area>/ROADMAP/competences/<slug>.md): id, stage in
                                          theory (T) and practice (P), targets in 12 and 24 months, the learning
                                          paths that name it (competence: in the path), title; a broken file warns
  paths [<area>] [--project=<id>] [--format=tsv|json]
                                          the learning paths: id, status, points, open points, progress in percent
                                          (of the XP, else of the points), title; --project: the paths of a project,
                                          the finished ones too (status done, 100 %)
  milestone-new <area> <title> [--due=YYYY-MM-DD] [--includes=<id>,<id>] [--close=manual] [--status=planning|doing|parked] [--summary=text] [--slug=]
                                          create the milestone ROADMAP/milestones/<slug>.md over tasks, plans,
                                          projects, paths and meetings of this vault; reached when they are all done
  milestones [<area>] [--format=tsv|json]  the milestones: id, status, due, progress (members done/all), title
  meeting new <area> <title> --date=YYYY-MM-DD [--time=HH:MM] [--end=HH:MM|--duration=45m] [--location=]
              [--online=url] [--tasks=a/b,c/d] [--notify=-15m,-1d@18:00] [--tags=] [--quick="<line>"] [--dry-run]
                                          make <area>/MEETINGS/<slug>.md (slug: title and date); --quick reads one
                                          line ("Mo 14:00-15:00 Sync @teams https://... #area/task !-15m"), the
                                          options win over it
  meeting set <id> --<field>=<value>      change a field (an empty value removes it); status planned|cancelled
  meeting close <id> [--result="<text>"]  done, at any time; the result goes into ## Ergebnis
  meeting followups <id> [--n=] [--area=] make tasks of the follow-ups (refs: the meeting; the id behind the line)
  meeting attend <id> <n|name> [--absent] tick (untick) a participant
  meeting show <id> [--format=json]       the meeting with participants and follow-ups (tasks.meeting)
  meeting parse "<line>"                  what the quick capture reads from a line (JSON; nothing written)
  meetings [area] [--since=] [--until=] [--task=<id>] [--format=json]
                                          the meetings of a window (default: 30 days back, 90 ahead)
  plan-close <area>/<slug>                finish a plan by hand (refused while a member task is open); the project it
                                          belongs to is finished after it when nothing else holds it open
  project-close <area>/<slug>             finish a project by hand (refused while an own task, or an open plan or
                                          learning path that is not parked, is left)
  plan [<area>] [--for=<id>|--plan=<id>] [--project=<id>] [filters as for list] [--ready] [--with-steps] [--format=md|tsv|ids]
       [--write=<file> [--scope=<name>] [--check] ]   replace only the generated block of a document
                                          stages, ready tasks, decisions by leverage, critical path
                                          (--for: the task and everything that has to be finished before it)
  next [<area>] [--n=3] [--actor=cdx|me|pair|none] [--not-category=a,b] [--format=text|json]   the best ready tasks, with the reason
                                          (--not-category: leave the ready tasks of these categories out, e.g. learning)
  call <method> [--params=<json>|-] [--pretty]   the machine contract (tasks-export/1): hello, snapshot, list, task, next,
                                          areas, done_preview and ops (the write door); `-` reads the JSON from stdin; the document
                                          on stdout, a tasks.error on failure (exit 1, 2 for a bad request)
  --capabilities                          the handshake document (call hello)
  show <area>/<slug> [--format=text|json]   one task: fields, readiness, body
  plans [<area>] [--tree]                 the plan files: id, status, location, title (--tree: under their project,
                                          indented, projects first with what they add up to)
  projects [<area>]                       the project files: id, status, location, title, plans finished/all, tasks
                                          finished/all, days still open, learning paths finished/all and their mean
                                          progress (paths 1/4 40 %)
  estimate [<area>] [--for=<id>] [filters as for list]   sums of effort and value, what is missing, quick wins
  list|plan|estimate @<name> [more options]   run a named list (see `lists`); options you give override its own
  lists [save <name>|delete <name>|rename <old> <new>|show <name>] [filters] [--sort=] [--area=] [--desc=]
                                          the named lists (built in, saved, from setup({ lists })); `save` stores the
                                          filters you give under a name, `delete` / `rename` change saved lists only
  quickwins [<area>] [--status=a,b] [--prio=..] [--kind=k] [--tag=t] [--category=c,d] [--actor=..] [--stale=..] [--plan=<id>]
       [--min-value=1..5] [--max-effort=XS..XL|0.5d] [--format=tsv|md|ids] [--by-actor] [--paths] [--report=<file>]
                                          the quick wins (value >= 4 and effort <= S, both written; thresholds from
                                          setup({ quick_wins })), best return first, plus the small tasks that miss a
                                          value; default status open,doing,decision. --report writes the Markdown
  index [<area>] [--check]                (re)write ROADMAP/TASKS.md; --check only reports
  index [<area>] --staged --check         whether the staged TASKS.md of the area (none: of every area with a staged
                                          change below ROADMAP/) is the one its staged tasks render to; reads only
                                          those areas, writes nothing; `stale<TAB>...` and exit 1 when not
  index <area> --staged                   build it from the staging area and stage it; the working tree stays as it
                                          is, so another session's uncommitted tasks stay out of the commit;
                                          lists the staged files of the area (`staged<TAB><path>`) and refuses a
                                          staging area with a conflict; notes when the tree keeps another index file (do not `git add` that one)
                                          index without an area also writes down the figures of today when the vault
                                          keeps a series (_Telemetry/history exists); --no-history leaves that out
  commit <path>... --message=<text> [--dry-run]
                                          commit only these paths of the vault (files or folders, deletions and the
                                          moves of done included) with the TASKS.md and Backlog README of the areas
                                          they touch, generated from that commit, from a staging area of its own:
                                          another session's staged files stay staged and out; signed when
                                          commit.gpgsign is set; runs no hooks; does not push
  push [<sha>...] [--attempts=n] [--dry-run] [--no-sync]
                                          push your own commits (the given ones, else every local commit not on
                                          origin/main) from a throwaway worktree on origin/main, so the pre-push hook
                                          sees only what goes out; a conflict in a generated file (TASKS.md,
                                          Backlog/README.md, history jsonl) is solved by rendering/union, any other
                                          conflict names the file; a rejected push starts again (default 5 times);
                                          then the shared checkout is rebased onto origin/main (--no-sync leaves it);
                                          never --no-verify. Prints `pushed <sha>`, `synced` and notes
  merge-driver install|status             git's merge driver for the generated TASKS.md (merge.tasks-index.driver, plus
                                          the lines in the vault's .gitattributes): a conflict in it is none; the
                                          next index render makes it right. `install` writes the git config of this
                                          repository (per machine) and the missing .gitattributes lines (uncommitted)
  merge-driver %O %A %B %P                what git runs: three-way merge by lines, ours kept when that conflicts
  hook install|status                     the vault's pre-commit hook (<git-common-dir>/hooks/pre-commit): refuses a
                                          commit whose staged TASKS.md is stale (index --staged --check); never
                                          overwrites another pre-commit hook
  history [<area>] [--since=YYYY-MM-DD] [--until=YYYY-MM-DD] [--resolution=day|week] [--format=tsv|json]
                                          the overview figures over time (open, ready, with value, ...; default: the
                                          last 90 days); '-' is a day before the first row, '*' a day with a row
  history record [--dry-run]              write down the figures of today: one row per area whose figures changed
                                          (and one per learning path whose figures changed, learn-YYYY-MM.jsonl)
                                          (<vault>/_Telemetry/history/YYYY-MM.jsonl, made on the first run)
  history backfill [--since=..] [--until=..] [--dry-run]
                                          fill the days before today that have a commit and no row from the history
                                          of the vault's repository (rows marked src: git; the repository is not touched)
  migrate-actor [<area>] [--write]        propose actor=me for tasks that wait for you (status decision, tag
                                          needs-user) and leave every other task EMPTY; dry run unless --write
  new <area>[,<area>...] <title> [--kind=k] [--prio=1..3] [--effort=XS..XL|0.5d] [--value=1..5] [--xp=N] [--actor=cdx|me|pair] [--after=id,id] [--order=2.5] [--plan=id|--project=id] [--phase=word] [--created=YYYY-MM-DD] [--tags=a,b]
       [--category=c,d] [--scope=a,b] [--severity=low|medium|high|critical] [--due=YYYY-MM-DD] [--start=YYYY-MM-DD] [--repeat=8w|1w,4w,12w] [--repeat-from=done|due] [--repeat-after=<id>|<path id>#<key>] [--refs=path,repo@sha] [--links=https://...,...]
       [--summary=text] [--slug=slug] [--status=s] [--waits-for=key] [--outcome=learned|seen|not-applicable] [--reason=text]
       [--icon=<emoji|assets/x.svg|word>] [--cover=assets/x.png]
       [--lang=de|en] [--folder]             create a task file (--lang: body headings;
                                               --folder: a folder task that can hold assets;
                                               --waits-for: created parked, waiting for that key;
                                               scopes: @SCOPES@)
  set <area>/<slug> key=value ... [--by=<name>] [--force --note=<why>]
                                          change frontmatter (empty value removes the key); waits_for=<key> parks
                                          the task with that reason, any other status drops the reason again; an id
                                          of a learning path, plan or project (no open task of that id) changes its
                                          file: title status areas target project links icon cover tags (a path),
                                          phase_order gate phase (a plan), as path_set / plan_set / project_set
  waits [<area>] [--format=tsv|json]      what the parked tasks wait for: per `waits_for` key the number of tasks
                                          and their areas, then the parked ones without a reason and the total
                                          (json: the tasks.waits document)
  release <key> [--dry-run]               bring back what waited for <key>: every parked task with waits_for=<key>
                                          gets status open and loses the key; --dry-run only names the tasks
  answer <area>/<slug> <q1|#n> <n|clear>  answer a question of the `## Offene Fragen` section: tick option n (1-based),
                                          or take the answer back (clear)
  promote <area>/<slug>#<key|n> [--area=a] [--title=t] [--actor=cdx|me|pair] [--tags=a,b] [--after=id,id] [--effort=XS..XL] [--dry-run] [--no-index]
                                          make a task of a learning point (of a path or a task's ## Lernpunkte): its
                                          subtree moves into the task, the point gets the arrow; done writes its state.
                                          The point's text is the summary line; on-workstation / not-on-workstation
                                          of the path (or task) come along; --no-index leaves the index as it is
  unpromote <area>/<slug>#<key|n> [--dry-run]
                                          take it back while the task holds no work (open, no commits, no assets)
  done <area>/<slug> [--ack] [--commits=repo@sha,repo@sha] [--done-in=text] [--date=YYYY-MM-DD] [--remind=7d|YYYY-MM-DD]
                                          [--by=<name>] [--force --note=<why>]  (a claimed task: see claim)
                                          [--no-next] [--unblock] [--last]  (--commits adds to the task's own `commits`)
                                          [--outcome=learned|seen|not-applicable] [--reason=text]  how it ended:
                                          seen and not-applicable need a reason (or the task's own outcome_reason)
                                          [--ci=pending|green|red]  the CI state of the commits (later:
                                          set <id> ci=green, on the finished task too)
                                          [--commit] [--commit-message=text]  commit what the finish wrote in the vault
                                          (as `tasks commit`, own staging area); without it a line `commit-paths`
                                          lists the paths for `tasks commit`
                                          finish: move to Backlog/; prints the tasks it freed and what to start
                                          next; --unblock sets the freed tasks that still say blocked to open;
                                          a routine (`repeat: 8w`) starts its next round (--last: it ends for good)
  reopen <area>/<slug> [--status=open|doing|blocked|parked|decision]
                                          bring a finished task back to ROADMAP/tasks (the id, or the name of its file
                                          in Backlog/): its row leaves Backlog/README.md, done_in and remind go, the
                                          index is written; an open task stays as it is; a folder task is refused
  intent <file|-> [--yes] [--lang=de|en]   take an intent `wkd-intent/1` (tasks.new, tasks.show): checked as untrusted input,
                                          prints what it would do (would_create, exists, shown), --yes creates the task
  claim <area>/<slug> [--by=<name>] [--for=4h] [--renew] [--force --note=<why>]
                                          reserve a task while you work on it (status doing); the same name renews,
                                          an expired claim is taken over, one of somebody else is refused;
                                          set, done, attach and folderize of a claimed task need the claim's name
                                          as --by=<name> (else: refused, as if somebody else held it)
  unclaim <area>/<slug> [--by=<name>] [--status=open|parked|decision] [--force --note=<why>]
                                          give it back (a doing task goes to open); `done` releases by itself
  attach <area>/<slug> <file> [--name=n] [--kind=video|image|screenshot] [--by=<name>] [--force --note=<why>]
                                          copy a file to <slug>/assets/ (a plain task becomes a folder task; a plan
                                          or project id too) and print the Markdown link
                                          --kind: into assets/videos/, assets/images/ or assets/screenshots/
                                          (--clipboard and --latest are screenshots without it)
  attach <area>/<slug> --clipboard [--name=n] [--by=<name>]
                                          the image on the clipboard, saved as a PNG named <slug>-<date>-<HHMM>.png
  attach <area>/<slug> --latest[=<folder>] [--name=n] [--by=<name>]
                                          the newest image of the screenshot folder(s) (config attach.screenshot_dirs),
                                          only when modified within attach.max_age_s (300 s); older: nothing is guessed
  folderize <area>/<slug> [--by=<name>] [--force --note=<why>]
                                          turn a plain task (or plan, project) file into a folder
  sheet-run <area>/<slug> [--testing-cli=<path>] [--dry-run]
                                          run the test sheets of a live-check task now: testing.nvim's
                                          `testing sheets run` runs them headless and writes their state into the
                                          task's block (red: the first failure line); its exit code (0 green, 1 red,
                                          2 refused: trust, workstation, no sheet; 3 testing.nvim or the engine
                                          not reached). testing.nvim: --testing-cli, $TESTING_NVIM_DIR,
                                          $REPOS_DIR/testing.nvim, <vault>/../testing.nvim, lazy
  sheet-ai draft|explain <area>/<slug>    the hand-over document for an AI (testing sheets prompt): a sheet to
                                          draft from the task, or the red run of its sheets to explain
  sheet-ai accept|bug <area>/<slug> --from=<answer file> [--yes]
                                          the sheet (testing sheets accept: only when it loads) or the bug task of
                                          the AI's answer; shown only, written with --yes
  check [<area>]                          rule check; exit 1 on any error
  check --sources [<file|dir>] [--write] [--fix] [--allow-host-change] [--timeout=<s>]
                                          ask the web links of the `## Quellen` table of a learning path (all open
                                          paths without an argument) with HEAD (GET as fallback): dead (404),
                                          blocked (401/403/429), moved; exit 1 on a dead link. Needs the network, so
                                          only on this flag, never in the hook. --write puts date and answer into
                                          the column Geprüft; --fix writes the target of a PERMANENT redirect
                                          (301, 308) into the link (`fixed` lines; a temporary one, a front page,
                                          a step back to http or ANOTHER HOST stays: `kept`; the host is compared
                                          without www., port and case; --allow-host-change takes a new host too,
                                          look at the `fixed old -> new` lines first)
  relink [<area>] [--dry-run]             mend the dead relative links to .md files below ROADMAP/, Backlog/ and
                                          MEETINGS/: a link whose slug names one file (a task finished into the
                                          Backlog, a folder task, another area) is rewritten to it; ambiguous and
                                          unresolved ones are listed. done, reopen, move and folderize keep the
                                          links that name the file they move on it by themselves
  template [--title=t] [--kind=k] [--prio=n] [--effort=e] [--tags=a,b] [--lang=de|en] [--with-plan]
  agent-brief [--format=md|json] [--by=<claim name>] [--repo=<dir>]   the brief for an AI agent: workflow (claim,
                                          set, new, done), allowed values and this command reference, with the
                                          contract version; --by is the claim name in its examples (default
                                          ai-desktop:<job>); --repo adds how that repository is checked before
                                          commit and push (its .testing.lua, else its CLAUDE.md); no vault
  ci [--strict] [--no-lint] [--md-lint=<file>] [--trust-vault-lint]   CI gate: check + index --check + md_lint of the
                                          generated indexes; exit 0/1 (--strict: warnings fail too; hints
                                          are shown as info lines and never fail).
                                          md_lint is a script RUN from the vault (TOOLS/scripts/md_lint.lua): it runs only with
                                          --trust-vault-lint (or TASKS_TRUST_VAULT_LINT=1); else --md-lint=<own copy> or --no-lint
  areas [--format=names|tsv|json]        list the vault's areas (tsv: with the open counts, then the area groups as
                                          <name> <open> group <members>; json: the tasks.areas document with area_groups)
                                          (an area group of <vault>/area-groups.json, e.g. nvim = *.nvim, stands for its
                                          member areas wherever list, plan, next, plans, estimate, quickwins take <area>;
                                          new refuses one: a task lives in one area)
  export [--top=N] [--no-links]           all-areas overview as Markdown on stdout (never written)
  import <area> --from-rules=<file|-> [--apply] [--lang=de|en]
                                          a work list of rules.nvim (rules-work-list/1) becomes tasks of the area: one
                                          per rule that fails or nobody judged; a rule with a task (open or finished),
                                          a waived and a passing one get none. A dry run unless --apply
  bootstrap <area> [--from-rules=<file|->] [--apply] [--lang=de|en]
                                          make the area (folders, READMEs, index; nothing overwritten), then import;
                                          a dry run unless --apply
  init-vault <dir> [--area=<name>] [--lang=de|en] [--force] [--apply]
                                          a new vault in <dir>: README, a first area (default Inbox) and an example
                                          task; nothing overwritten; a dry run unless --apply (try examples/vault first)

global options: --vault=<dir> (default: $TASKS_VAULT; no built-in default path)
                --today=YYYY-MM-DD (for reproducible runs); --no-index on new/set/done
]]
-- The category words come from the model, so --help, `new --category`, `set` and `check` never disagree.
USAGE = USAGE:gsub("@CATEGORIES@", function()
  return table.concat(model.CATEGORIES, " ")
end)

USAGE = USAGE:gsub("@SCOPES@", function()
  return table.concat(model.SCOPES, " ")
end)

---@class Tasks.CliSpec
---@field value string[]   # Options that need `=value`.
---@field flag string[]    # Options without a value.

---@type table<string, Tasks.CliSpec>
local SPECS = {
  list = {
    value = {
      "status",
      "prio",
      "effort",
      "kind",
      "tag",
      "category",
      "severity",
      "waits-for",
      "outcome",
      "ci",
      "value",
      "actor",
      "stale",
      "plan",
      "project",
      "phase",
      "sort",
      "format",
      "limit",
      "offset",
      "sheet",
      "claimed",
      "due-before",
      "starts-after",
      "by",
    },
    flag = {
      "blocked",
      "all",
      "done",
      "reminders",
      "overdue",
      "stale-refs",
      "ready",
      "waiting",
      "unestimated",
      "quick-win",
    },
  },
  plan = {
    value = {
      "for",
      "plan",
      "project",
      "write",
      "scope",
      "status",
      "prio",
      "effort",
      "kind",
      "tag",
      "category",
      "severity",
      "waits-for",
      "value",
      "actor",
      "stale",
      "phase",
      "format",
    },
    flag = { "blocked", "stale-refs", "ready", "unestimated", "with-steps", "check", "quick-win" },
  },
  estimate = {
    value = {
      "for",
      "plan",
      "project",
      "status",
      "prio",
      "effort",
      "kind",
      "tag",
      "category",
      "severity",
      "waits-for",
      "value",
      "actor",
      "stale",
      "phase",
    },
    flag = { "blocked", "stale-refs", "unestimated", "quick-win" },
  },
  lists = {
    value = {
      "status",
      "prio",
      "effort",
      "kind",
      "category",
      "severity",
      "waits-for",
      "value",
      "actor",
      "tag",
      "sheet",
      "claimed",
      "stale",
      "plan",
      "phase",
      "sort",
      "desc",
      "area",
    },
    flag = { "blocked", "reminders", "stale-refs", "unestimated", "quick-win", "ready", "waiting" },
  },
  quickwins = {
    value = {
      "plan",
      "project",
      "status",
      "prio",
      "kind",
      "tag",
      "category",
      "severity",
      "waits-for",
      "actor",
      "stale",
      "min-value",
      "max-effort",
      "format",
      "report",
    },
    flag = { "blocked", "stale-refs", "unestimated", "by-actor", "paths" },
  },
  next = { value = { "n", "actor", "format", "by", "not-category" }, flag = {} },
  ["plan-new"] = {
    value = {
      "areas",
      "target",
      "phases",
      "gate",
      "status",
      "summary",
      "slug",
      "title",
      "links",
      "icon",
      "cover",
      "template",
    },
    flag = {},
  },
  ["project-new"] = {
    value = {
      "areas",
      "target",
      "phases",
      "gate",
      "status",
      "summary",
      "slug",
      "title",
      "links",
      "icon",
      "cover",
      "template",
      "requires",
      "requires-gate",
    },
    flag = {},
  },
  path = { value = { "format", "machine" }, flag = { "schedule", "write" } },
  paths = { value = { "project", "format" }, flag = {} },
  ["path-new"] = {
    value = {
      "areas",
      "target",
      "status",
      "summary",
      "slug",
      "title",
      "links",
      "icon",
      "cover",
      "project",
      "template",
      "tags",
      "from",
      "requires",
      "requires-gate",
    },
    -- `--no-index` for scripts that pass it to every writing command: a new path changes no index
    flag = { "no-index", "dry-run" },
  },
  ["plan-close"] = { value = {}, flag = {} },
  ["milestone-new"] = {
    value = { "due", "includes", "close", "status", "summary", "slug", "title" },
    flag = {},
  },
  milestones = { value = { "format" }, flag = {} },
  ["project-close"] = { value = {}, flag = {} },
  meeting = {
    value = {
      "date",
      "time",
      "end",
      "duration",
      "tz",
      "location",
      "online",
      "tasks",
      "notify",
      "notify-to",
      "tags",
      "icon",
      "cover",
      "image",
      "recording",
      "summary",
      "status",
      "title",
      "slug",
      "lang",
      "quick",
      "result",
      "n",
      "area",
      "format",
    },
    flag = { "dry-run", "absent" },
  },
  meetings = { value = { "since", "until", "task", "format" }, flag = {} },
  index = { value = {}, flag = { "check", "all", "staged", "no-history" } },
  hook = { value = {}, flag = {} },
  push = { value = { "attempts" }, flag = { "dry-run", "no-sync" } },
  ["merge-driver"] = { value = {}, flag = {} },
  commit = { value = { "message" }, flag = { "dry-run" } },
  new = {
    value = {
      "created",
      "kind",
      "prio",
      "effort",
      "tags",
      "category",
      "scope",
      "severity",
      "value",
      "xp",
      "actor",
      "after",
      "order",
      "plan",
      "project",
      "phase",
      "refs",
      "links",
      "icon",
      "cover",
      "due",
      "start",
      "repeat",
      "repeat-from",
      "repeat-after",
      "lang",
      "summary",
      "slug",
      "status",
      "title",
      "waits-for",
      "outcome",
      "reason",
    },
    flag = { "no-index", "folder" },
  },
  set = { value = { "by", "note" }, flag = { "no-index", "force" } },
  claim = { value = { "by", "for", "note" }, flag = { "renew", "force" } },
  unclaim = { value = { "by", "note", "status" }, flag = { "force" } },
  intent = { value = { "lang" }, flag = { "yes" } },
  waits = { value = { "format" }, flag = {} },
  release = { value = {}, flag = { "dry-run", "no-index" } },
  answer = { value = {}, flag = { "no-index" } },
  promote = {
    value = { "area", "title", "actor", "tags", "after", "effort" },
    flag = { "dry-run", "no-index" },
  },
  unpromote = { value = {}, flag = { "dry-run", "no-index" } },
  ["migrate-actor"] = { value = {}, flag = { "write", "no-index" } },
  done = {
    value = {
      "done-in",
      "commits",
      "ci",
      "date",
      "remind",
      "by",
      "note",
      "outcome",
      "reason",
      "commit-message",
    },
    flag = { "no-index", "no-next", "unblock", "last", "force", "ack", "commit" },
  },
  reopen = { value = { "status" }, flag = {} },
  point = { value = { "state", "reason" }, flag = { "ack" } },
  -- `latest` is both: `--latest` (the configured screenshot folders) and `--latest=<folder>`.
  attach = {
    value = { "name", "kind", "latest", "by", "note" },
    flag = { "no-index", "clipboard", "latest", "force" },
  },
  folderize = { value = { "by", "note" }, flag = { "no-index", "force" } },
  ["sheet-run"] = { value = { "testing-cli" }, flag = { "dry-run" } },
  ["sheet-ai"] = { value = { "testing-cli", "from" }, flag = { "yes" } },
  check = {
    value = { "timeout" },
    flag = { "all", "allow-host-change", "fix", "sources", "write" },
  },
  relink = { value = {}, flag = { "dry-run" } },
  ci = { value = { "md-lint" }, flag = { "strict", "no-lint", "trust-vault-lint" } },
  template = {
    value = { "title", "kind", "prio", "effort", "tags", "lang" },
    flag = { "with-plan" },
  },
  ["agent-brief"] = { value = { "format", "by", "repo" }, flag = {} },
  areas = { value = { "format" }, flag = {} },
  export = { value = { "top", "link-prefix" }, flag = { "no-links" } },
  import = { value = { "from-rules", "lang" }, flag = { "apply", "dry-run" } },
  bootstrap = { value = { "from-rules", "lang" }, flag = { "apply", "dry-run" } },
  ["init-vault"] = { value = { "area", "lang" }, flag = { "apply", "dry-run", "force" } },
}

local GLOBAL_VALUE = { "vault", "today" }

---@class Tasks.CliArgs
---@field pos string[]
---@field opt table<string, string|boolean>

---@param argv string[]
---@param spec Tasks.CliSpec
---@return Tasks.CliArgs|nil args
---@return string|nil err
local function parse_args(argv, spec)
  local value, flag = {}, { help = true }
  for _, k in ipairs(spec.value) do
    value[k] = true
  end
  for _, k in ipairs(GLOBAL_VALUE) do
    value[k] = true
  end
  for _, k in ipairs(spec.flag) do
    flag[k] = true
  end
  local pos, opt = {}, {}
  local options_done = false
  for _, token in ipairs(argv) do
    if options_done or token:sub(1, 2) ~= "--" then
      pos[#pos + 1] = token
    elseif token == "--" then
      options_done = true
    else
      local name, val = token:match("^%-%-([%w][%w-]*)=(.*)$")
      if name then
        if not value[name] then
          return nil, "unknown or valueless option: --" .. name
        end
        opt[name] = val
      else
        name = token:sub(3)
        if flag[name] then
          opt[name] = true
        elseif value[name] then
          return nil, ("option needs a value: --%s=<value>"):format(name)
        else
          return nil, "unknown option: " .. token
        end
      end
    end
  end
  -- An empty `--vault=` (a shell variable that was not set) must not quietly mean "the default
  -- vault": a command meant for a scratch copy would write to the real one.
  for _, k in ipairs(GLOBAL_VALUE) do
    if opt[k] == "" then
      return nil, ("option needs a value: --%s=<value>"):format(k)
    end
  end
  return { pos = pos, opt = opt }, nil
end

local filter_opts = require("tasks_nvim.filter_opts")
local split_commas = filter_opts.split_commas

---Make a line safe to print: terminal control characters (ESC and the other C0 controls, DEL,
---a lone CR, the 8-bit C1 controls such as the CSI `U+009B`) become `?`. A task title comes
---from a file anyone may have edited, and it would otherwise reach the terminal verbatim.
---Tab and newline stay: they are the output format.
---@param text string
---@return string
local function clean(text)
  text = text:gsub("\r\n", "\n")
  text = text:gsub("[%z\1-\8\11-\31\127]", "?")
  text = text:gsub("\194[\128-\159]", "?")
  return text
end

---@param value string
---@param what string
---@return integer|nil
---@return string|nil err
local function to_int(value, what)
  if not value:match("^%d+$") then
    return nil, ("%s must be a whole number, got '%s'"):format(what, value)
  end
  return tonumber(value), nil
end

---The filter options as `filter_opts.parse` takes them (also what a marker block records).
---@param opt table<string, string|boolean>
---@return table
local function filter_option_map(opt)
  return {
    status = opt.status --[[@as string|nil]],
    prio = opt.prio --[[@as string|nil]],
    effort = opt.effort --[[@as string|nil]],
    kind = opt.kind --[[@as string|nil]],
    tag = opt.tag --[[@as string|nil]],
    category = opt.category --[[@as string|nil]],
    severity = opt.severity --[[@as string|nil]],
    waits_for = opt["waits-for"] --[[@as string|nil]],
    outcome = opt.outcome --[[@as string|nil]],
    ci = opt.ci --[[@as string|nil]],
    value = opt.value --[[@as string|nil]],
    actor = opt.actor --[[@as string|nil]],
    stale = opt.stale --[[@as string|nil]],
    stale_refs = opt["stale-refs"] == true,
    plan = opt.plan --[[@as string|nil]],
    project = opt.project --[[@as string|nil]],
    phase = opt.phase --[[@as string|nil]],
    blocked = opt.blocked == true,
    reminders = opt.reminders == true,
    overdue = opt.overdue == true,
    due_before = opt["due-before"] --[[@as string|nil]],
    starts_after = opt["starts-after"] --[[@as string|nil]],
    unestimated = opt.unestimated == true,
    quick_win = opt["quick-win"] == true,
    sheet = opt.sheet --[[@as string|nil]],
    claimed = opt.claimed --[[@as string|nil]],
    today = opt.today --[[@as string|nil]],
  }
end

---Turn the filter options into a `Tasks.Filter` (the parsing itself is shared
---with the editor commands: `filter_opts.parse`).
---@param opt table<string, string|boolean>
---@return Tasks.Filter|nil filter
---@return string|nil err
local function filter_from(opt)
  return filter_opts.parse(filter_option_map(opt))
end

---@param opt table<string, string|boolean>
---@return table opts  engine options shared by every command
local function engine_opts(opt)
  return {
    root = opt.vault --[[@as string|nil]],
    today = opt.today --[[@as string|nil]],
  }
end

---`--by`, `--force`, `--note` of a write: who changes the task, and whether a claim of somebody else may be passed.
---@param opt table<string, string|boolean>
---@return { by?: string, force: boolean, note?: string }
local function claim_opts(opt)
  return {
    by = opt.by --[[@as string|nil]],
    force = opt.force == true,
    note = opt.note --[[@as string|nil]],
  }
end

---@param s any
---@return string
local function cellv(s)
  if s == nil or s == "" then
    return "-"
  end
  return (tostring(s):gsub("[\t\r\n]+", " "))
end

---@class Tasks.CliCtx
---@field io Tasks.CliIO
---@field args Tasks.CliArgs
---@field say fun(line: string)
---@field warn fun(line: string)
---@field out fun(text: string)   # Like `io.out`, with control characters cleaned.
---@field eo table

---@type table<string, fun(ctx: Tasks.CliCtx): integer>
local commands = {}

function commands.list(ctx)
  local args, eo = ctx.args, ctx.eo
  local filter, ferr = filter_from(args.opt)
  if not filter then
    ctx.warn("error: " .. ferr)
    return 2
  end
  filter.ref_opts = { root = eo.root }
  local order, serr = model.parse_sort(args.opt.sort)
  if not order then
    ctx.warn("error: " .. serr)
    return 2
  end
  local format = args.opt.format or "tsv"
  if format ~= "tsv" and format ~= "ids" and format ~= "json" then
    ctx.warn("error: --format must be tsv, ids or json")
    return 2
  end
  if #args.pos > 1 then
    ctx.warn("error: list takes at most one area")
    return 2
  end
  if format ~= "json" and (args.opt.limit ~= nil or args.opt.offset ~= nil) then
    ctx.warn("error: --limit and --offset go with --format=json")
    return 2
  end
  if
    args.opt.done and (format == "json" or args.opt.ready or args.opt.waiting or args.opt.sort)
  then
    ctx.warn(
      "error: --done lists the finished tasks as tsv or ids; it takes no --sort, --ready, --waiting or json form"
    )
    return 2
  end

  local area
  -- `all` means every area, as it does for plan, next and estimate
  if args.pos[1] == "all" then
    args.pos[1] = nil
  end
  if args.pos[1] and not args.opt.all then
    local root, rerr = vault.root(eo)
    if not root then
      ctx.warn("error: " .. tostring(rerr))
      return 1
    end
    -- an area group (`list nvim`) is a filter name like an area
    if not vault.area_scope(root, args.pos[1]) then
      ctx.warn("error: unknown area: " .. args.pos[1])
      return 1
    end
    area = args.pos[1]
  end
  if args.opt.done then
    return contract_cli.list_done(ctx, filter, area, format, contract_helpers)
  end
  if format == "json" then
    return contract_cli.list_json(ctx, filter, area, contract_helpers)
  end
  local open, skipped, errors = scan.open_tasks(vim.tbl_extend("force", eo, { area = area }))
  if not open then
    ctx.warn("error: " .. tostring(skipped))
    return 1
  end
  -- `--stale=refs`: the second result of `model.filter` is the report that names the changed files.
  local filtered, report = model.filter(open, filter)
  if args.opt.ready or args.opt.waiting then
    if args.opt.ready and args.opt.waiting then
      ctx.warn("error: --ready and --waiting exclude each other")
      return 2
    end
    -- The same definition of "ready" as the plan, the dashboard and `next`.
    local kept, kerr = plan_scope.filter_readiness(
      filtered,
      args.opt.ready and "ready" or "waiting",
      eo.root,
      nil,
      eo.today,
      args.opt.by --[[@as string|nil]]
    )
    if not kept then
      ctx.warn("error: " .. tostring(kerr))
      return 1
    end
    filtered = kept
  end
  local shown = model.sort(filtered, order)
  for _, t in ipairs(shown) do
    if format == "ids" then
      ctx.say(fsio.clean(t.id))
    else
      local cells = {
        fsio.clean(t.id),
        cellv(t.status),
        cellv(t.prio),
        cellv(t.effort),
        cellv(t.kind),
        cellv(t.updated or t.created),
        cellv(t.title),
      }
      -- a trailing cell, only for a parked task that names a reason: every other line stays what it was
      local mark = waits.mark(t)
      if mark then
        cells[#cells + 1] = mark
      end
      if report then
        cells[#cells + 1] = "changed: " .. staleness.describe(report.stale[t.id] or {}, 5)
      end
      ctx.say(table.concat(cells, "\t"))
    end
  end
  if report then
    for _, note in ipairs(report.notes) do
      ctx.warn("note: " .. note)
    end
    ctx.warn(
      ("note: --stale=refs checked %d file(s) of %d task(s); %d ref(s) found nowhere, %d skipped (commits, anchors, undated)"):format(
        report.files,
        report.tasks,
        report.unresolved,
        report.skipped
      )
    )
  end
  if skipped > 0 then
    ctx.warn(
      ("note: %d task file(s) not listed (missing or unknown status, or done); run `check`"):format(
        skipped
      )
    )
  end
  if type(errors) == "table" and #errors > 0 then
    for _, e in ipairs(errors) do
      ctx.warn("warn: cannot read directory " .. e)
    end
    return 1
  end
  return 0
end

---The area argument shared by `plan`, `next` and `estimate`: an area or an area group.
---@param ctx Tasks.CliCtx
---@param name string  The command, for the message.
---@return string|nil area
---@return boolean ok
local function area_arg(ctx, name)
  local given = ctx.args.pos[1]
  if #ctx.args.pos > 1 then
    ctx.warn("error: " .. name .. " takes at most one area")
    return nil, false
  end
  if not given then
    return nil, true
  end
  local root, rerr = vault.root(ctx.eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return nil, false
  end
  if not vault.area_scope(root, given) then
    ctx.warn("error: unknown area: " .. given)
    return nil, false
  end
  return given, true
end

---@param ctx Tasks.CliCtx
---@param name string
---@return Tasks.PlanScope|nil scope
---@return integer|nil code  # Set when the command must stop.
local function load_scope(ctx, name)
  local area, ok = area_arg(ctx, name)
  if not ok then
    return nil, 2
  end
  local filter, ferr = filter_from(ctx.args.opt)
  if not filter then
    ctx.warn("error: " .. ferr)
    return nil, 2
  end
  filter.ref_opts = { root = ctx.eo.root }
  local scope, err = plan_scope.load({
    root = ctx.eo.root,
    area = area,
    for_id = ctx.args.opt["for"] --[[@as string|nil]],
    plan_id = ctx.args.opt.plan --[[@as string|nil]],
    -- one project: its head (goal, stages) too. Not for a block written into a document (`--write`): the marker
    -- records the filter only, so the refresh would not build the same block with a head
    project_id = (
      not ctx.args.opt.write
      and type(ctx.args.opt.project) == "string"
      and not ctx.args.opt.project:find(",", 1, true)
    )
        and ctx.args.opt.project --[[@as string]]
      or nil,
    filter = filter,
  })
  if not scope then
    ctx.warn("error: " .. tostring(err))
    return nil, 1
  end
  for _, e in ipairs(scope.errors) do
    ctx.warn("warn: cannot read directory " .. e)
  end
  return scope, nil
end

---`plan --write=<file>`: replace only the marker block of the scope in a hand-written document (`--check`: report
---whether it is out of date and write nothing).
---@param ctx Tasks.CliCtx
---@param scope Tasks.PlanScope
---@param path string
---@return integer code
local function write_plan_block(ctx, scope, path)
  local opt = ctx.args.opt
  local key = opt.scope --[[@as string|nil]]
    or plan_view.default_scope({
      area = ctx.args.pos[1],
      for_id = opt["for"] --[[@as string|nil]],
      plan_id = opt.plan --[[@as string|nil]],
    })
  ---@type string|nil
  local area = ctx.args.pos[1]
  if area == "all" then
    area = nil
  end
  -- The marker records how the block was made (target, view, filters): the refresh after a finish builds the same.
  local attrs, aerr = plan_scope.marker_attrs(
    filter_option_map(opt),
    { ready = opt.ready == true, steps = opt["with-steps"] == true },
    {
      area = area,
      plan_id = opt.plan --[[@as string|nil]],
      for_id = opt["for"] --[[@as string|nil]],
      root = ctx.eo.root,
    },
    key
  )
  if not attrs then
    ctx.warn("error: " .. tostring(aerr))
    return 2
  end
  local res, err =
    plan_scope.write_block(path, scope, { key = key, attrs = attrs, check = opt.check == true })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("%s\t%s"):format(res.state, path))
  return res.state == "stale" and 1 or 0
end

function commands.plan(ctx)
  local format = ctx.args.opt.format or "md"
  if format ~= "md" and format ~= "tsv" and format ~= "ids" then
    ctx.warn("error: --format must be md, tsv or ids")
    return 2
  end
  local scope, code = load_scope(ctx, "plan")
  if not scope then
    return code or 1
  end
  local ready_only = ctx.args.opt.ready == true
  local write_to = ctx.args.opt.write --[[@as string|nil]]
  if write_to then
    return write_plan_block(ctx, scope, fsio.doc_path(write_to))
  end
  if ctx.args.opt.check then
    ctx.warn("error: --check goes with --write=<file>")
    return 2
  end
  if format == "ids" then
    for _, id in ipairs(plan_view.ids(scope.plan, { ready_only = ready_only })) do
      ctx.say(fsio.clean(id))
    end
  elseif format == "tsv" then
    for _, line in ipairs(plan_view.tsv(scope.plan, { ready_only = ready_only })) do
      ctx.say(line)
    end
  else
    ctx.out(plan_view.markdown(scope.plan, {
      title = scope.title,
      today = ctx.eo.today or model.today(),
      done = scope.done,
      ready_only = ready_only,
      with_steps = ctx.args.opt["with-steps"] == true,
      plan_file = scope.plan_file,
    }))
  end
  return #scope.errors > 0 and 1 or 0
end

function commands.estimate(ctx)
  local scope, code = load_scope(ctx, "estimate")
  if not scope then
    return code or 1
  end
  local sums = estimate.rollup(scope.tasks, { done = scope.done })
  ctx.say(estimate.describe(sums))
  if #sums.quick_wins > 0 then
    ctx.say("quick wins: " .. table.concat(sums.quick_wins, ", "))
  end
  if #sums.unestimated > 0 then
    ctx.say(("unestimated: %d (list them: list --unestimated)"):format(#sums.unestimated))
  end
  return #scope.errors > 0 and 1 or 0
end

---The quick-win thresholds of one run: the config, then `--min-value` / `--max-effort` over it.
---@param opt table<string, string|boolean>
---@return Tasks.QuickWinThresholds|nil th
---@return string|nil err
local function quick_win_thresholds(opt)
  local th = estimate.thresholds()
  if opt["min-value"] ~= nil then
    local v = model.to_value(opt["min-value"])
    if not v then
      return nil, "--min-value must be 1..5, got " .. tostring(opt["min-value"])
    end
    th.value = v
  end
  if opt["max-effort"] ~= nil then
    local raw = tostring(opt["max-effort"])
    local norm = raw:match("^%a+$") and raw:upper() or raw:lower()
    local days = model.effort_days(norm)
    if not days then
      return nil, "--max-effort must be XS..XL or days like 0.5d, got " .. raw
    end
    th.effort, th.days = norm, days
  end
  return th, nil
end

function commands.quickwins(ctx)
  local opt = ctx.args.opt
  local format = opt.format or "tsv"
  if format ~= "md" and format ~= "tsv" and format ~= "ids" then
    ctx.warn("error: --format must be md, tsv or ids")
    return 2
  end
  local th, terr = quick_win_thresholds(opt)
  if not th then
    ctx.warn("error: " .. tostring(terr))
    return 2
  end
  if opt.status == nil and opt["waits-for"] == nil then
    -- A parked or blocked task is not something to start: the default is what can be picked up. `--waits-for` asks
    -- for parked tasks, so it leaves the default out.
    opt.status = "open,doing,decision"
  end
  local scope, code = load_scope(ctx, "quickwins")
  if not scope then
    return code or 1
  end
  local report = quick_wins.build(scope.tasks, th)
  local text_opts =
    { title = scope.title, by_actor = opt["by-actor"] == true, paths = opt.paths == true }
  local rc = #scope.errors > 0 and 1 or 0
  if opt.report then
    local ok, where = quick_wins.write(tostring(opt.report), quick_wins.markdown(report, text_opts))
    if not ok then
      ctx.warn("error: " .. where)
      return 1
    end
    ctx.say("wrote\t" .. where)
    return rc
  end
  if format == "ids" then
    for _, id in ipairs(quick_wins.ids(report)) do
      ctx.say(id)
    end
  elseif format == "md" then
    ctx.out(quick_wins.markdown(report, text_opts))
  else
    for _, line in ipairs(quick_wins.tsv(report)) do
      ctx.say(line)
    end
  end
  return rc
end

---The list a `lists save` stores: the filter words of the command line as a definition.
---@param opt table<string, string|boolean>
---@return Tasks.ListDef
local function def_from_options(opt)
  local def = {}
  for _, key in ipairs({
    "status",
    "prio",
    "effort",
    "kind",
    "category",
    "severity",
    "value",
    "actor",
    "tag",
    "sheet",
    "claimed",
    "stale",
    "plan",
    "phase",
    "sort",
    "desc",
    "area",
  }) do
    if opt[key] ~= nil then
      def[key] = tostring(opt[key])
    end
  end
  if opt["waits-for"] ~= nil then
    def.waits_for = tostring(opt["waits-for"])
  end
  def.blocked = opt.blocked == true or nil
  def.reminders = opt.reminders == true or nil
  def.unestimated = opt.unestimated == true or nil
  def.stale_refs = opt["stale-refs"] == true or nil
  def.quick_win = opt["quick-win"] == true or nil
  if opt.ready and opt.waiting then
    def.readiness = "both"
  else
    def.readiness = (opt.ready and "ready") or (opt.waiting and "waiting") or nil
  end
  return def
end

---Does the command take this option word (`--effort` is `value`, `--blocked` is `flag`)?
---@param spec Tasks.CliSpec
---@param flag string
---@return boolean
local function takes(spec, flag)
  return vim.tbl_contains(spec.value, flag) or vim.tbl_contains(spec.flag, flag)
end

---`list|plan|estimate @<name>`: the named list's options under the ones given on the command line (a word you
---typed wins), its area when no area was typed. A word of the list the command has no use for is an error, never
---dropped (`estimate @small-and-important` must not quietly leave out "startable"); only `sort` may be left over,
---it is a way to order, not a way to select.
---@param args { pos: string[], opt: table }
---@param name string
---@param command string
---@return string|nil err
local function apply_list(args, name, command)
  local entry, err = lists.get(name)
  if not entry then
    return err
  end
  local resolved, rerr = lists.resolve(entry.def)
  if not resolved then
    return rerr
  end
  local spec = SPECS[command]
  ---@type { flag: string, value: any }[]
  local overlay = {}
  for key, value in pairs(entry.def) do
    if key == "readiness" then
      overlay[#overlay + 1] = { flag = value, value = true }
    elseif key ~= "desc" and key ~= "area" then
      local flag = key:gsub("_", "-")
      if key == "stale_refs" and not takes(spec, flag) then
        -- `--stale=refs` is the same filter where the flag itself does not exist
        overlay[#overlay + 1] = { flag = "stale", value = "refs" }
      else
        overlay[#overlay + 1] = { flag = flag, value = value == true and true or tostring(value) }
      end
    end
  end
  for _, o in ipairs(overlay) do
    if o.flag ~= "sort" and not takes(spec, o.flag) then
      return ("list '%s' sets --%s, which `%s` does not take"):format(name, o.flag, command)
    end
  end
  table.remove(args.pos, 1)
  for _, o in ipairs(overlay) do
    if o.flag == "ready" or o.flag == "waiting" then
      if args.opt.ready == nil and args.opt.waiting == nil then
        args.opt[o.flag] = true
      end
    elseif args.opt[o.flag] == nil then
      args.opt[o.flag] = o.value
    end
  end
  if entry.def.area and args.pos[1] == nil then
    args.pos[1] = entry.def.area
  end
  return nil
end

---@class Tasks.ListsSub
---@field usage string  Shown on a wrong argument count (exit 2)
---@field names integer  How many names follow the subcommand (exactly)
---@field run fun(ctx: Tasks.CliCtx, a: string, b: string): integer  `b` is only set when `names` is 2

--- Report a failed `lists.*` call the way every subcommand does.
---@param ctx Tasks.CliCtx
---@param err any
---@return integer code
local function lists_fail(ctx, err)
  ctx.warn("error: " .. tostring(err))
  return 1
end

---@type table<string, Tasks.ListsSub>
local LISTS_SUBS = {
  show = {
    usage = "lists show <name>",
    names = 1,
    run = function(ctx, name)
      local entry, err = lists.get(name)
      if not entry then
        return lists_fail(ctx, err)
      end
      ctx.say(("%s\t%s"):format(entry.name, entry.source))
      if entry.def.desc then
        ctx.say("desc: " .. fsio.clean(entry.def.desc))
      end
      ctx.say(
        "tasks list "
          .. (entry.def.area and (entry.def.area .. " ") or "")
          .. table.concat(lists.words(entry.def), " ")
      )
      return 0
    end,
  },
  save = {
    usage = "lists save <name> [filters] [--sort=] [--area=] [--desc=]",
    names = 1,
    run = function(ctx, name)
      local def = def_from_options(ctx.args.opt)
      if def.readiness == "both" then
        ctx.warn("error: --ready and --waiting exclude each other")
        return 2
      end
      local saved, err = lists.save(name, def)
      if not saved then
        return lists_fail(ctx, err)
      end
      ctx.say(("saved\t%s\t%s"):format(name, lists.path()))
      return 0
    end,
  },
  delete = {
    usage = "lists delete <name>",
    names = 1,
    run = function(ctx, name)
      local deleted, err = lists.delete(name)
      if not deleted then
        return lists_fail(ctx, err)
      end
      ctx.say(("deleted\t%s"):format(name))
      return 0
    end,
  },
  rename = {
    usage = "lists rename <old> <new>",
    names = 2,
    run = function(ctx, old, new)
      local renamed, err = lists.rename(old, new)
      if not renamed then
        return lists_fail(ctx, err)
      end
      ctx.say(("renamed\t%s\t%s"):format(old, new))
      return 0
    end,
  },
}

---@param ctx Tasks.CliCtx
---@return integer code
function commands.lists(ctx)
  local args = ctx.args
  local sub = args.pos[1]
  if sub == nil or sub == "ls" then
    local entries, notes = lists.all()
    for _, e in ipairs(entries) do
      ctx.say(table.concat({ e.name, e.source, lists.summary(e.def) }, "\t"))
    end
    for _, n in ipairs(notes) do
      ctx.warn("warn: " .. n)
    end
    return 0
  end
  local entry = LISTS_SUBS[sub]
  if not entry then
    ctx.warn("error: unknown lists command: " .. tostring(sub) .. " (save, delete, rename, show)")
    return 2
  end
  if args.pos[1 + entry.names] == nil or #args.pos > 1 + entry.names then
    ctx.warn("error: usage: " .. entry.usage)
    return 2
  end
  return entry.run(ctx, args.pos[2], args.pos[3])
end

---The usage line of `plan-new`, `project-new` and `path-new`.
---@type table<string, string>
local NEW_FILE_USAGE = {
  plan = 'plan-new <area> "<title>" [--slug=s] [--areas=a,b] [--target=id] [--phases=a,b,c] [--gate=hard] [--template=learning]',
  project = 'project-new <area> "<title>" [--slug=s] [--areas=a,b] [--target=id] [--phases=a,b,c] [--gate=hard] [--requires=id,id] [--requires-gate=soft|hard] [--template=learning]',
  path = 'path-new <area> "<title>" [--slug=s] [--areas=a,b] [--target=id] [--project=id] [--requires=id,id] [--requires-gate=soft|hard] [--tags=a,b] [--template=learning] [--no-index] [--dry-run]',
}

---`plan-new`, `project-new` and `path-new`: make the file (`plans.new` with `kind`) and say its id.
---@param ctx Tasks.CliCtx
---@param kind "plan"|"project"|"path"
---@return integer code
local function new_file_command(ctx, kind)
  local args, eo = ctx.args, ctx.eo
  local area = args.pos[1]
  local title = args.pos[2] or args.opt.title
  if not area or not title or #args.pos > 2 then
    ctx.warn("error: usage: " .. NEW_FILE_USAGE[kind])
    return 2
  end
  local res, err = require("tasks_nvim.plans").new(area, {
    root = eo.root,
    today = eo.today,
    kind = kind ~= "plan" and kind or nil,
    title = title,
    areas = args.opt.areas --[[@as string|nil]],
    target = args.opt.target --[[@as string|nil]],
    phases = args.opt.phases --[[@as string|nil]],
    gate = args.opt.gate --[[@as string|nil]],
    status = args.opt.status --[[@as string|nil]],
    summary = args.opt.summary --[[@as string|nil]],
    slug = args.opt.slug --[[@as string|nil]],
    web_links = args.opt.links --[[@as string|nil]],
    icon = args.opt.icon --[[@as string|nil]],
    cover = args.opt.cover --[[@as string|nil]],
    project = args.opt.project --[[@as string|nil]],
    template = args.opt.template --[[@as "learning"|nil]],
    tags = args.opt.tags --[[@as string|nil]],
    requires = args.opt.requires --[[@as string|nil]],
    requires_gate = args.opt["requires-gate"] --[[@as string|nil]],
    -- only `path-new` takes `--dry-run` (for `--from`); without it the flag must not write either
    dry_run = args.opt["dry-run"] == true,
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  if args.opt["dry-run"] == true then
    ctx.say(("would-create\t%s\t%s"):format(res.id, res.path))
    return 0
  end
  ctx.say(("created\t%s\t%s"):format(res.id, res.path))
  if res.ambiguous then
    ctx.warn("warn: " .. require("tasks_nvim.wikilinks").ambiguity_message(res.ambiguous))
  end
  return 0
end

commands["plan-new"] = function(ctx)
  return new_file_command(ctx, "plan")
end

commands["project-new"] = function(ctx)
  return new_file_command(ctx, "project")
end

---`path-new <area> --from=<draft.md> [--slug=s] [--dry-run]`: a whole path from a draft (`tasks_nvim.path_draft`).
---Exit 0: written (or, with `--dry-run`, it would be); 1: a finding refused it or the call failed; 2: usage.
---@param ctx Tasks.CliCtx
---@return integer code
local function path_from_draft(ctx)
  local args, eo = ctx.args, ctx.eo
  local usage = "path-new <area> --from=<draft.md> [--slug=s] [--dry-run]"
  local area = args.pos[1]
  local source = args.opt.from
  if not area or #args.pos > 1 or type(source) ~= "string" or source == "" then
    ctx.warn("error: usage: " .. usage)
    return 2
  end
  -- the draft holds the frontmatter: an option that would write one of its keys has no place beside it
  for _, key in ipairs({
    "title",
    "areas",
    "target",
    "status",
    "summary",
    "links",
    "icon",
    "cover",
    "project",
    "template",
    "tags",
  }) do
    if args.opt[key] ~= nil then
      ctx.warn(("error: --%s goes into the draft's frontmatter, not beside --from"):format(key))
      return 2
    end
  end
  local draft, rerr = fsio.read(source)
  if not draft then
    ctx.warn("error: cannot read " .. source .. ": " .. tostring(rerr))
    return 1
  end
  local res, err = require("tasks_nvim.path_draft").run(area, draft, {
    root = eo.root,
    today = eo.today,
    slug = args.opt.slug --[[@as string|nil]],
    dry_run = args.opt["dry-run"] == true,
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  -- `<severity>\t<code>\tline N: <message>`: the line is the draft's, also when the message did not name one
  local function line_out(word, f)
    return ("%s\t%s\tline %d: %s"):format(word, f.code, f.line, (f.message:gsub("^line %d+: ", "")))
  end
  for _, f in ipairs(res.findings) do
    ctx.warn(line_out(f.severity, f))
  end
  for _, h in ipairs(res.hints) do
    ctx.warn(line_out("hint", h))
  end
  if #res.findings > 0 then
    ctx.warn(("refused\t%d finding(s); nothing written"):format(#res.findings))
    return 1
  end
  ctx.say(("%s\t%s\t%s"):format(res.written and "created" or "would-create", res.id, res.path))
  if res.renamed then
    ctx.warn("warn: the slug was taken: the path is " .. res.id)
  end
  return 0
end

commands["path-new"] = function(ctx)
  if ctx.args.opt.from ~= nil then
    return path_from_draft(ctx)
  end
  return new_file_command(ctx, "path")
end

---`point <area>/<slug> <key|#n> --state=s [--reason=text] [--ack]`: change one learning point through the operation
---`node_set`; closing a point under `{safety}` needs `--ack`.
---@param ctx Tasks.CliCtx
---@return integer code
commands.point = function(ctx)
  local args = ctx.args
  local id, ref = args.pos[1], args.pos[2]
  local state = args.opt.state
  if not id or not ref or #args.pos > 2 or type(state) ~= "string" then
    ctx.warn(
      "error: usage: point <area>/<slug> <key|#n> --state=open|learned|seen|dropped|blocked [--reason=text] [--ack]"
    )
    return 2
  end
  local doc, err = require("tasks_nvim.ops").run({
    ops = {
      {
        op = "node_set",
        id = id,
        point = ref,
        state = state,
        reason = args.opt.reason,
        ack = args.opt.ack == true or nil,
      },
    },
  }, { root = ctx.eo.root, today = ctx.eo.today })
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return 1
  end
  local entry = doc.results[1]
  if not entry.ok then
    ctx.warn(("error: %s (%s)"):format(tostring(entry.error.message), tostring(entry.error.code)))
    return entry.error.code == "invalid_argument" and 2 or 1
  end
  ctx.say(
    ("%s\t%s\t%s\t%s"):format(
      entry.outcome,
      entry.id,
      entry.node.key and ("#" .. entry.node.key) or ("line " .. entry.node.line),
      entry.node.state
    )
  )
  return 0
end

---`path <area>/<slug> [--machine=m] [--format=text|json]`: the XP overview of an open learning path (`path_stats`).
---`--schedule [--write]`: the table of `## Zeitplan` made from the tree (`path_schedule`), shown or written.
---@param ctx Tasks.CliCtx
---@return integer code
commands.path = function(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  local format = args.opt.format or "text"
  local schedule, write = args.opt.schedule == true, args.opt.write == true
  if
    not id
    or #args.pos > 1
    or (format ~= "text" and format ~= "json")
    or (write and not schedule)
    or (schedule and (args.opt.format ~= nil or args.opt.machine ~= nil))
  then
    ctx.warn(
      "error: usage: path <area>/<slug> [--machine=private|workstation|wsl|env|all] [--format=text|json]  |  path <area>/<slug> --schedule [--write]"
    )
    return 2
  end
  local lern = require("tasks_nvim.lernbaum")
  local machine, machine_note
  if args.opt.machine ~= nil then
    local m = tostring(args.opt.machine)
    if m ~= "all" then
      machine = lern.machine_of_role(m == "env" and (os.getenv("NVIM_MACHINE_ROLE") or "") or m)
      if not machine then
        ctx.warn("error: --machine takes private, workstation, wsl, env or all, not '" .. m .. "'")
        return 2
      end
    end
  elseif format == "text" and not schedule then
    -- without --machine the text shows what goes on this machine (`NVIM_MACHINE_ROLE`); JSON stays whole, a script
    -- reads the marks itself. An unknown role filters nothing and says so.
    local role = os.getenv("NVIM_MACHINE_ROLE") or ""
    machine = lern.machine_of_role(role)
    if machine then
      machine_note = "from NVIM_MACHINE_ROLE; --machine=all shows every point"
    else
      ctx.say(
        ("note\tNVIM_MACHINE_ROLE '%s' is no machine (private, workstation, wsl): nothing is filtered"):format(
          clean(role)
        )
      )
    end
  end
  if schedule then
    local sched = require("tasks_nvim.path_schedule")
    if write then
      local res, werr =
        require("tasks_nvim.paths").write_schedule(id, { root = eo.root, today = eo.today })
      if not res then
        ctx.warn("error: " .. tostring(werr))
        return 1
      end
      ctx.say(
        ("schedule\t%s\t%d rows\t%s"):format(
          res.id,
          res.rows,
          res.changed and "written" or "unchanged"
        )
      )
      return 0
    end
    local sfile, serr = require("tasks_nvim.paths").find(id, { root = eo.root })
    if not sfile then
      ctx.warn("error: " .. tostring(serr))
      return 1
    end
    local lines = sched.render(sched.rows(sfile.tree or require("tasks_nvim.lernbaum").parse("")))
    if not lines then
      ctx.warn("error: no point carries {h=…}: nothing to put in ## Zeitplan")
      return 1
    end
    for _, l in ipairs(lines) do
      ctx.say(l)
    end
    return 0
  end
  local file, err = require("tasks_nvim.paths").find(id, { root = eo.root })
  if not file then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  local tree = file.tree or require("tasks_nvim.lernbaum").parse("")
  -- what the path builds on: a hard gate keeps the line of the whole path open while it waits
  local req = require("tasks_nvim.requires")
  local rst = ((file.requires and #file.requires > 0) or file.project)
      and req.state(file, req.index({ root = eo.root }))
    or nil
  local st = require("tasks_nvim.path_stats").compute(
    tree,
    file.levels,
    req.hold_levels(file.level_state, rst)
  )
  local marks = require("tasks_nvim.path_stats").marks(tree, machine)
  if format == "json" then
    ctx.say(vim.json.encode({
      safety = marks.safety,
      machine = machine and { role = machine, hidden = marks.hidden, todo = marks.todo } or nil,
      id = file.id,
      title = file.title,
      status = file.status,
      requires = rst and rst.requirements or nil,
      requires_gate = rst and rst.gate or nil,
      waiting_on = rst and rst.waiting or nil,
      has_xp = st.has_xp,
      points = st.points,
      xp = st.xp,
      optional = st.optional,
      level = st.level,
      stages = st.stages,
      without_xp = st.without_xp,
      levels = st.levels,
    }))
    return 0
  end
  ---@param pt? { key?: string, label: string, line: integer }
  ---@return string
  local function name(pt)
    if not pt then
      return "-"
    end
    return (pt.key and ("#" .. pt.key .. " ") or "")
      .. clean(pt.label)
      .. (" (line %d)"):format(pt.line)
  end
  local p, x = st.points, st.xp
  ctx.say(
    ("path\t%s\t%s\t%s"):format(file.id, tostring(file.status or "-"), clean(file.title or ""))
  )
  -- the safety points come first: a reader (or an AI) goes past none of them
  for _, sp in ipairs(marks.safety) do
    ctx.say(
      ("safety\t%s\t%s\t(line %d)"):format(
        sp.key and ("#" .. sp.key) or "-",
        clean(sp.label),
        sp.line
      )
    )
  end
  for _, r in ipairs(rst and rst.requirements or {}) do
    ctx.say(
      ("requires\t%s\t%s\t%s\t%s"):format(
        r.id,
        r.kind == "unknown" and "unknown" or (r.met and "done" or "open"),
        r.gate,
        clean(r.title or "")
      )
    )
  end
  if rst then
    ctx.say(("gate\t%s\t%s"):format(rst.gate, req.waiting_text(rst) or "nothing open"))
  end
  ctx.say(
    ("points\t%d\topen %d\tlearned %d\tseen %d\tdropped %d\twithout xp %d"):format(
      p.total,
      p.open,
      p.learned,
      p.seen,
      p.dropped,
      p.without_xp
    )
  )
  ctx.say(("xp\t%d\tearned %d\topen %d"):format(x.total, x.earned, x.open))
  -- optional points (`{optional}`): apart, never in the counts above, the levels in percent or the path being done
  local o = st.optional
  if o then
    ctx.say(
      ("optional\t%d\topen %d\tlearned %d\tseen %d\tdropped %d\txp %d\tearned %d"):format(
        o.points,
        o.open,
        o.learned,
        o.seen,
        o.dropped,
        o.xp,
        o.earned
      )
    )
  end
  for _, s in ipairs(st.stages) do
    ctx.say(
      ("stage\t%d\txp %d\tpoints %d\topen %d\twithout xp %d\t%s%s"):format(
        s.number,
        s.xp,
        s.points,
        s.open,
        s.without_xp,
        clean(s.label),
        s.optional and "\toptional" or ""
      )
    )
  end
  if machine then
    ctx.say(
      ("machine\t%s\thidden %d\topen here %d%s"):format(
        machine,
        marks.hidden,
        #marks.todo,
        machine_note and ("\t" .. machine_note) or ""
      )
    )
    for _, t in ipairs(marks.todo) do
      ctx.say(
        ("todo\t%s\t%s\t(line %d)%s%s"):format(
          t.key and ("#" .. t.key) or "-",
          clean(t.label),
          t.line,
          t.safety and "\tsafety" or "",
          t.under and ("\tunder: " .. clean(t.under.label)) or ""
        )
      )
    end
  end
  local counted = p.counted
  for _, l in ipairs(st.levels) do
    local what
    if l.kind == "xp" then
      what = ("%d XP"):format(l.threshold)
    elseif l.kind == "percent" then
      what = ("%d %%"):format(l.threshold)
        .. (l.needed and (st.has_xp and " = %g XP" or " = %g points"):format(l.needed) or "")
    else
      what = "path done"
    end
    local at
    if l.at_start then
      at = "at the start"
    elseif l.at then
      at = ("at point %d/%d, stage %d: %s"):format(l.at.index, counted, l.at.stage, name(l.at))
    else
      at = "not reachable"
    end
    ctx.say(
      ("level\t%s\t%s\t%s\t%s\t%s"):format(
        l.ref,
        what,
        l.name and clean(l.name) or "-",
        l.reached and "reached" or "open",
        at
      )
    )
  end
  local by_line = {}
  for _, n in ipairs(tree.nodes) do
    by_line[n.line] = n
  end
  for _, pt in ipairs(st.without_xp) do
    -- with --machine a point that does not go here is not shown (it is counted in `hidden`)
    local node = by_line[pt.line]
    if not (machine and node and not lern.on_machine(node, machine)) then
      ctx.say(("without-xp\tstage %d\t%s"):format(pt.stage, name(pt)))
    end
  end
  return 0
end

---`commit <path>... --message=<text> [--dry-run]`: commit only these paths of the vault, with the generated index and
---Backlog README of the areas they touch, from a staging area of its own (`tasks_nvim.vault_commit`). Prints
---`committed`, then one `path` line per changed file, `index` per area, and a note for generated files whose copy in
---the tree differs from the committed one.
---@param ctx Tasks.CliCtx
---@return integer code
commands.commit = function(ctx)
  local args = ctx.args
  if #args.pos == 0 or not args.opt.message then
    ctx.warn("error: commit takes paths of the vault and --message=<text>")
    return 2
  end
  local dry = args.opt["dry-run"] == true
  local res, err = require("tasks_nvim.vault_commit").commit(args.pos, {
    root = ctx.eo.root,
    message = args.opt.message --[[@as string]],
    dry_run = dry,
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  if dry then
    ctx.say(("would-commit\t%d path(s)"):format(#res.paths))
  else
    ctx.say(("committed\t%s\t%d path(s)"):format(res.commit:sub(1, 9), #res.paths))
  end
  for _, p in ipairs(res.paths) do
    ctx.say("path\t" .. p)
  end
  for _, r in ipairs(res.indexes) do
    ctx.say(("index\t%s\t%s\t%d open"):format(r.area, r.action, r.open))
  end
  for _, p in ipairs(res.tree_differs) do
    ctx.warn(
      ("note: the tree's %s is not the committed one (it counts every session's files); leave it, or"):format(
        p
      ) .. (" `git checkout -- %s` in a checkout of your own"):format(p)
    )
  end
  if res.settle_error then
    ctx.warn(
      "warn: the shared staging area still holds the old version of the committed paths: "
        .. res.settle_error
    )
  end
  return 0
end

---`push [<sha>...]`: `tasks_nvim.vault_push`. Exit 1 when nothing could be pushed (the reason on stderr), 0 otherwise
---(also when there was nothing to push).
---@param ctx Tasks.CliCtx
---@return integer code
commands.push = function(ctx)
  local args = ctx.args
  local attempts = args.opt.attempts and tonumber(args.opt.attempts) or nil
  if args.opt.attempts and (not attempts or attempts < 1 or attempts % 1 ~= 0) then
    ctx.warn("error: --attempts takes a whole number >= 1")
    return 2
  end
  local res, err = require("tasks_nvim.vault_push").push({
    root = ctx.eo.root,
    shas = args.pos,
    attempts = attempts,
    dry_run = args.opt["dry-run"] == true,
    sync = args.opt["no-sync"] ~= true,
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  if #res.picked == 0 then
    ctx.say("nothing to push")
    return 0
  end
  if args.opt["dry-run"] == true then
    for _, s in ipairs(res.picked) do
      ctx.say("would-push	" .. s:sub(1, 9))
    end
    return 0
  end
  for _, s in ipairs(res.pushed) do
    ctx.say(("pushed	%s	try %d"):format(s:sub(1, 9), res.attempt))
  end
  ctx.say(res.sync == "synced" and "synced" or ("sync	" .. res.sync))
  for _, n in ipairs(res.notes) do
    ctx.warn("note: " .. n)
  end
  if res.leftover then
    ctx.warn("warn: the worktree could not be removed (remove it by hand): " .. res.leftover)
  end
  return res.sync:sub(1, 6) == "failed" and 1 or 0
end

---`merge-driver install|status`, or what git runs (`%O %A %B %P`).
---@param ctx Tasks.CliCtx
---@return integer code
commands["merge-driver"] = function(ctx)
  local pos = ctx.args.pos
  local vm = require("tasks_nvim.vault_merge")
  if #pos == 4 then
    local result, err = vm.driver(pos[1], pos[2], pos[3])
    if not result then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    return 0
  end
  local sub = pos[1]
  if (sub ~= "install" and sub ~= "status") or #pos > 1 then
    ctx.warn("error: merge-driver takes install or status")
    return 2
  end
  local res, err
  if sub == "install" then
    res, err = vm.install({ root = ctx.eo.root })
    if res then
      ctx.say(("%s	%s"):format(res.driver, vm.NAME))
      for _, l in ipairs(res.added) do
        ctx.say(("attribute	%s	%s"):format(res.file, l))
      end
      if #res.added > 0 then
        ctx.warn(
          "note: .gitattributes is changed in the working tree; commit it (`tasks commit .gitattributes`)"
        )
      end
      return 0
    end
  else
    res, err = vm.status({ root = ctx.eo.root })
    if res then
      ctx.say(
        ("%s	%s	attributes %s"):format(res.state, vm.NAME, res.attributes and "ok" or "missing")
      )
      return (res.state == "installed" and res.attributes) and 0 or 1
    end
  end
  ctx.warn("error: " .. tostring(err))
  return 1
end

---`hook install|status`: the vault's pre-commit hook (`tasks_nvim.vault_hook`). `status` prints the state
---(`installed`, `outdated`, `absent`, `foreign`) and the file, exit 1 unless installed; `install` writes it, exit 1
---when another pre-commit hook is in the way.
---@param ctx Tasks.CliCtx
---@return integer code
commands.hook = function(ctx)
  local sub = ctx.args.pos[1]
  if (sub ~= "install" and sub ~= "status") or #ctx.args.pos > 1 then
    ctx.warn("error: hook takes install or status")
    return 2
  end
  local vault_hook = require("tasks_nvim.vault_hook")
  local res, err
  if sub == "install" then
    res, err = vault_hook.install({ root = ctx.eo.root })
  else
    res, err = vault_hook.status({ root = ctx.eo.root })
  end
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  local state = res.state --[[@as string]]
  if sub == "install" then
    state = res.state == "installed" and "unchanged"
      or (res.state == "outdated" and "updated" or "installed")
  end
  ctx.say(("%s\t%s"):format(state, res.path))
  if res.hooks_path then
    ctx.warn(
      ("note: core.hooksPath is %s: git runs this hook only if that folder's pre-commit hands over to it"):format(
        res.hooks_path
      )
    )
  end
  if sub == "status" and res.state ~= "installed" then
    return 1
  end
  return 0
end

---`relink [<area>] [--dry-run]`: mend the dead relative links (`relink.repair`). One line per link: `relinked` (or
---`would-relink`), `ambiguous` with the candidates, `unresolved`; then a summary. Exit 1 when a file could not be
---written.
---@param ctx Tasks.CliCtx
---@return integer code
commands.relink = function(ctx)
  local area, area_ok = area_arg(ctx, "relink")
  if not area_ok then
    return 2
  end
  local root, rerr = vault.root(ctx.eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local names
  if area then
    local scope = vault.area_scope(root, area)
    names = vim.tbl_keys(scope and scope.set or { [area] = true })
  end
  local dry = ctx.args.opt["dry-run"] == true
  local res = require("tasks_nvim.relink").repair(root, names, { dry_run = dry })
  local base = fsio.norm(root) .. "/"
  local function rel(p)
    p = fsio.norm(p)
    return p:sub(1, #base) == base and p:sub(#base + 1) or p
  end
  for _, e in ipairs(res.edits) do
    ctx.say(
      ("%s\t%s:%d\t%s\t%s"):format(
        dry and "would-relink" or "relinked",
        rel(e.path),
        e.line,
        e.from,
        e.to
      )
    )
  end
  for _, a in ipairs(res.ambiguous) do
    ctx.say(
      ("ambiguous\t%s:%d\t%s\t%s"):format(
        rel(a.path),
        a.line,
        a.target,
        table.concat(vim.tbl_map(rel, a.candidates), ", ")
      )
    )
  end
  for _, u in ipairs(res.unresolved) do
    ctx.say(("unresolved\t%s:%d\t%s"):format(rel(u.path), u.line, u.target))
  end
  for _, e in ipairs(res.errors) do
    ctx.warn("error: " .. e)
  end
  ctx.say(
    ("relink: %s %d link(s) in %d file(s); %d ambiguous, %d without a file of that slug"):format(
      dry and "would rewrite" or "rewrote",
      res.links,
      #res.files,
      #res.ambiguous,
      #res.unresolved
    )
  )
  return #res.errors > 0 and 1 or 0
end

---`paths [<area>] [--project=<id>] [--format=tsv|json]`: the open learning paths (and, with `--project`, the finished
---ones of that project) with their progress: id, status, points, open points, percent, title.
---@param ctx Tasks.CliCtx
---@return integer code
commands.paths = function(ctx)
  local args, eo = ctx.args, ctx.eo
  local format = args.opt.format or "tsv"
  if format ~= "tsv" and format ~= "json" then
    ctx.warn("error: usage: paths [<area>] [--project=<id>] [--format=tsv|json]")
    return 2
  end
  local area, area_ok = area_arg(ctx, "paths")
  if not area_ok then
    return 2
  end
  local paths_mod = require("tasks_nvim.paths")
  local projects = require("tasks_nvim.projects")
  local root, rerr = vault.root(eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local files, err = paths_mod.all({ root = root })
  if not files then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  -- an area group stands for its member areas
  local scope = area and vault.area_scope(root, area) or nil
  local in_area = area and (scope and scope.set or { [area] = true }) or nil
  local rows
  local project = args.opt.project
  if project ~= nil then
    local pid, perr = require("tasks_nvim.wikilinks").typed_id(
      tostring(project),
      "project",
      require("tasks_nvim.wikilinks").resolver(root)
    )
    if not pid then
      ctx.warn("error: " .. tostring(perr))
      return 2
    end
    if not projects.find(pid, { root = root }) then
      ctx.warn("error: no such open project: " .. pid)
      return 1
    end
    local finished = projects.finished_items({ root = root })
    local project_files = projects.all({ root = root }) or {}
    local idx = require("tasks_nvim.requires").any(files, project_files)
        and require("tasks_nvim.requires").index({
          root = root,
          paths = files,
          projects = project_files,
          finished = finished,
        })
      or nil
    rows = projects.path_rows(pid, files, finished, idx)
  else
    local project_files = projects.all({ root = root }) or {}
    local idx = require("tasks_nvim.requires").any(files, project_files)
        and require("tasks_nvim.requires").index({
          root = root,
          paths = files,
          projects = project_files,
        })
      or nil
    rows = {}
    for _, f in ipairs(files) do
      rows[#rows + 1] = projects.path_row(f, idx)
    end
  end
  if in_area then
    rows = vim.tbl_filter(function(r)
      return in_area[r.id:match("^([^/]+)/")] == true
    end, rows)
  end
  if format == "json" then
    ctx.say(vim.json.encode({ paths = rows }))
    return 0
  end
  for _, r in ipairs(rows) do
    ctx.say(("%s\t%s\tpoints %d\topen %d\t%d %%\t%s%s"):format(
      clean(r.id),
      clean(r.status),
      r.points,
      r.open,
      r.percent,
      clean(r.title or ""),
      -- what the path waits for (or builds on), last, so the columns before stay where they were
      r.wait and ("\t" .. clean(r.wait)) or ""
    ))
  end
  return 0
end

-- ── meetings ─────────────────────────────────────────────────────────────────

---The options of `meeting new` and `meeting set` that are fields of the meeting (`--end` is `end`).
local MEETING_FIELD_OPTS = {
  "date",
  "time",
  "end",
  "duration",
  "tz",
  "location",
  "online",
  "tasks",
  "notify",
  "notify-to",
  "tags",
  "icon",
  "cover",
  "image",
  "recording",
  "summary",
  "status",
  "title",
}

---The fields the options name (`--tasks=a,b` a list; `--x=` an empty value, which `set` reads as "remove").
---@param opt table<string, any>
---@return table<string, any>
local function meeting_fields(opt)
  local out = {}
  for _, key in ipairs(MEETING_FIELD_OPTS) do
    local value = opt[key]
    if type(value) == "string" then
      local field = key:gsub("%-", "_")
      if field == "tasks" or field == "notify" or field == "notify_to" or field == "tags" then
        local list = {}
        for item in value:gmatch("[^,]+") do
          list[#list + 1] = vim.trim(item)
        end
        out[field] = list
      else
        out[field] = value
      end
    end
  end
  return out
end

---Send one operation through the write door and say how it went: `<outcome>\t<id>` and the notes; the error of a
---failed one. The entry, for more lines.
---@param ctx Tasks.CliCtx
---@param op table
---@param dry boolean
---@param upload_dir? string
---@return integer code
---@return table|nil entry
local function meeting_op(ctx, op, dry, upload_dir)
  local eo = ctx.eo
  local doc, err = require("tasks_nvim.ops").run(
    { ops = { op }, dry_run = dry or nil },
    { root = eo.root, today = eo.today, attach = upload_dir and { upload_dir = upload_dir } or nil }
  )
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return 1, nil
  end
  local entry = doc.results[1]
  if not entry.ok then
    ctx.warn(("error: %s (%s)"):format(tostring(entry.error.message), tostring(entry.error.code)))
    return entry.error.code == "invalid_argument" and 2 or 1, entry
  end
  ctx.say(("%s\t%s"):format(entry.outcome, entry.id or ""))
  for _, note in ipairs(entry.notes or {}) do
    ctx.warn("note: " .. note)
  end
  return 0, entry
end

---@type table<string, fun(ctx: Tasks.CliCtx, rest: string[]): integer>
local MEETING_SUBS = {}

MEETING_SUBS.new = function(ctx, rest)
  local opt = ctx.args.opt
  local area, title = rest[1], rest[2]
  local fields = meeting_fields(opt)
  if type(opt.quick) == "string" then
    -- the line of the quick capture first, the options win over it
    local proposal = require("tasks_nvim.meeting_quick").parse(opt.quick, { today = ctx.eo.today })
    for _, p in ipairs(proposal.problems) do
      ctx.warn("warn: not read: " .. p)
    end
    fields = vim.tbl_extend("force", proposal.fields, fields)
    title = title or (proposal.title ~= "" and proposal.title or nil)
  end
  fields.title = nil
  if not area or not title then
    ctx.warn(
      'error: usage: meeting new <area> "<title>" --date=YYYY-MM-DD [--time=HH:MM] [--end=HH:MM|--duration=45m] [--quick="<line>"]'
    )
    return 2
  end
  local code = meeting_op(ctx, {
    op = "meeting_new",
    area = area,
    title = title,
    fields = fields,
    slug = opt.slug,
    lang = opt.lang,
  }, opt["dry-run"] == true)
  return code
end

MEETING_SUBS.set = function(ctx, rest)
  local id = rest[1]
  local patch = meeting_fields(ctx.args.opt)
  if not id or next(patch) == nil then
    ctx.warn(
      "error: usage: meeting set <area>/<slug> --<field>=<value> (an empty value removes the field)"
    )
    return 2
  end
  for key, value in pairs(patch) do
    if value == "" then
      patch[key] = vim.NIL
    end
  end
  return (
    meeting_op(ctx, { op = "meeting_set", id = id, patch = patch }, ctx.args.opt["dry-run"] == true)
  )
end

MEETING_SUBS.close = function(ctx, rest)
  local id = rest[1]
  if not id then
    ctx.warn('error: usage: meeting close <area>/<slug> [--result="<text>"]')
    return 2
  end
  local code, entry = meeting_op(ctx, {
    op = "meeting_close",
    id = id,
    result = ctx.args.opt.result,
  }, ctx.args.opt["dry-run"] == true)
  if entry and entry.ok and entry.without_result then
    ctx.say("without-result\t" .. entry.id)
  end
  return code
end

MEETING_SUBS.followups = function(ctx, rest)
  local id = rest[1]
  if not id then
    ctx.warn("error: usage: meeting followups <area>/<slug> [--n=<line>] [--area=<area>]")
    return 2
  end
  local n = ctx.args.opt.n and tonumber(ctx.args.opt.n) or nil
  local code, entry = meeting_op(ctx, {
    op = "meeting_followups",
    id = id,
    n = n,
    area = ctx.args.opt.area,
  }, ctx.args.opt["dry-run"] == true)
  for _, item in ipairs(entry and entry.items or {}) do
    if item.ok then
      ctx.say(("task\t%d\t%s"):format(item.n, item.id))
    else
      ctx.warn(("error: follow-up %d: %s"):format(item.n, tostring(item.error)))
      code = 1
    end
  end
  return code
end

MEETING_SUBS.attend = function(ctx, rest)
  local id, who = rest[1], rest[2]
  if not id or not who then
    ctx.warn("error: usage: meeting attend <area>/<slug> <number|name> [--absent]")
    return 2
  end
  local n = who:match("^%d+$") and tonumber(who) or nil
  return (
    meeting_op(ctx, {
      op = "meeting_attend",
      id = id,
      n = n,
      name = not n and who or nil,
      present = ctx.args.opt.absent ~= true,
    }, ctx.args.opt["dry-run"] == true)
  )
end

MEETING_SUBS.show = function(ctx, rest)
  local id = rest[1]
  if not id then
    ctx.warn("error: usage: meeting show <area>/<slug> [--format=json]")
    return 2
  end
  local doc, err = contract.meeting(id, { root = ctx.eo.root })
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return 1
  end
  if ctx.args.opt.format == "json" then
    ctx.out(vim.json.encode(doc) .. "\n")
    return 0
  end
  local m = doc.meeting or doc
  ctx.say(("%s\t%s\t%s %s\t%s"):format(m.id, m.status, m.date or "", m.time or "", m.title))
  -- the lists are the document's; the entry has their counts
  for _, p in ipairs(doc.participants or {}) do
    ctx.say(("participant\t%d\t%s\t%s"):format(p.n, p.present and "x" or " ", p.name))
  end
  for _, f in ipairs(doc.followups or {}) do
    ctx.say(("followup\t%d\t%s\t%s\t%s"):format(f.n, f.ticked and "x" or " ", f.text, f.task or ""))
  end
  return 0
end

MEETING_SUBS.parse = function(ctx, rest)
  if #rest == 0 then
    ctx.warn('error: usage: meeting parse "<line>"')
    return 2
  end
  local proposal =
    require("tasks_nvim.meeting_quick").parse(table.concat(rest, " "), { today = ctx.eo.today })
  ctx.out(vim.json.encode(proposal) .. "\n")
  return 0
end

---`tasks meeting <new|show|set|close|followups|attend|parse> ...`
---@param ctx Tasks.CliCtx
---@return integer code
commands.meeting = function(ctx)
  local sub = ctx.args.pos[1]
  local run = sub and MEETING_SUBS[sub]
  if not run then
    ctx.warn("error: usage: meeting <new|show|set|close|followups|attend|parse> ...")
    return 2
  end
  return run(ctx, vim.list_slice(ctx.args.pos, 2))
end

---`tasks meetings [area] [--since= --until=] [--task=<id>] [--format=tsv|json]`: the meetings of a window, the earliest
---first (`tasks.meetings`).
---@param ctx Tasks.CliCtx
---@return integer code
commands.meetings = function(ctx)
  local opt = ctx.args.opt
  local doc, err = contract.meetings({
    area = ctx.args.pos[1],
    since = opt.since,
    ["until"] = opt["until"],
    task = opt.task,
  }, { root = ctx.eo.root, today = ctx.eo.today })
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return type(err) == "table" and err.code == "invalid_argument" and 2 or 1
  end
  if opt.format == "json" then
    ctx.out(vim.json.encode(doc) .. "\n")
    return 0
  end
  for _, m in ipairs(doc.items or {}) do
    ctx.say(("%s\t%s\t%s\t%s"):format(m.id, m.starts_at or m.date or "", m.status, m.title))
  end
  return 0
end

---Say which milestones a write reached or opened again, one line each (`milestone-reached`, `milestone-reopened`).
---@param ctx table
---@param reached? string[]
---@param reopened? string[]
local function say_milestones(ctx, reached, reopened)
  for _, id in ipairs(reached or {}) do
    ctx.say(("milestone-reached\t%s"):format(id))
  end
  for _, id in ipairs(reopened or {}) do
    ctx.say(("milestone-reopened\t%s"):format(id))
  end
end

---`tasks milestone-new <area> "<title>" [--due= --includes= --close= --status= --summary= --slug=]`.
---@param ctx Tasks.CliCtx
---@return integer code
commands["milestone-new"] = function(ctx)
  local args, eo = ctx.args, ctx.eo
  local area = args.pos[1]
  local title = args.pos[2] or args.opt.title
  if not area or not title or #args.pos > 2 then
    ctx.warn(
      'error: usage: milestone-new <area> "<title>" [--due=YYYY-MM-DD] [--includes=a/b,c/d] [--close=manual]'
    )
    return 2
  end
  local res, err, info = require("tasks_nvim.milestones").new(area, {
    root = eo.root,
    today = eo.today,
    title = title,
    due = args.opt.due --[[@as string|nil]],
    includes = args.opt.includes --[[@as string|nil]],
    close = args.opt.close --[[@as string|nil]],
    status = args.opt.status --[[@as string|nil]],
    summary = args.opt.summary --[[@as string|nil]],
    slug = args.opt.slug --[[@as string|nil]],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    for _, p in ipairs(info and info.details and info.details.problems or {}) do
      ctx.warn(("  %s\t%s"):format(p.code, p.target))
    end
    return info and info.code == "invalid_argument" and 2 or 1
  end
  ctx.say(("created\t%s\t%s"):format(res.id, res.path))
  -- made over members that are all done already: reached at once
  local settled = require("tasks_nvim.milestones").settle({ root = eo.root, today = eo.today })
  say_milestones(ctx, settled.reached, settled.reopened)
  return 0
end

---`tasks milestones [area] [--format=tsv|json]`: the milestones with status, due and progress (`tasks.milestones`).
---@param ctx Tasks.CliCtx
---@return integer code
commands.milestones = function(ctx)
  local doc, err = contract.milestones(
    { area = ctx.args.pos[1] },
    { root = ctx.eo.root, today = ctx.eo.today }
  )
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return type(err) == "table" and err.code == "not_found" and 2 or 1
  end
  if ctx.args.opt.format == "json" then
    ctx.out(vim.json.encode(doc) .. "\n")
    return 0
  end
  for _, m in ipairs(doc.items or {}) do
    ctx.say(
      ("%s\t%s\t%s\t%d/%d%s\t%s"):format(
        m.id,
        m.status or "?",
        m.due or "-",
        m.progress.members_done,
        m.progress.members,
        m.overdue and " overdue" or "",
        m.title
      )
    )
  end
  return 0
end

---Say what a hand-made close did, one line each.
---@param ctx table
---@param plans_closed string[]
---@param plan_summaries table<string, table>
---@param projects Tasks.ClosedProjects
local function say_closed(ctx, plans_closed, plan_summaries, projects)
  for _, plan_id in ipairs(plans_closed) do
    ctx.say(
      ("plan-closed\t%s\t%s"):format(
        plan_id,
        plan_view.plan_closed_text(plan_id, plan_summaries[plan_id])
      )
    )
  end
  for _, project_id in ipairs(projects.closed) do
    ctx.say(
      ("project-closed\t%s\t%s"):format(
        project_id,
        plan_view.project_closed_text(project_id, projects.summaries[project_id])
      )
    )
  end
  for _, note in ipairs(projects.notes) do
    ctx.warn("warn: " .. note)
  end
end

---`plan-close <id>` / `project-close <id>`: finish by hand (`done_flow.close_by_hand`), the same as `:Tasks plan-close`.
---@param ctx table
---@param kind "plan"|"project"
---@return integer
local function close_by_hand(ctx, kind)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 then
    ctx.warn(("error: usage: %s-close <area>/<slug>"):format(kind))
    return 2
  end
  local res = done_flow.close_by_hand(kind, id, { root = eo.root, today = eo.today })
  if res.already then
    ctx.say(("already	%s	%s"):format(id, res.already))
    return 0
  end
  -- the notes of the plan or project come before the verdict (those of a project a plan took with it after it)
  for _, note in ipairs(res.notes) do
    ctx.warn("warn: " .. note)
  end
  if res.holding then
    local n = #res.holding
    local s = n == 1 and "" or "s"
    local what = kind == "plan" and ("task" .. s)
      or ("task" .. s .. ", plan" .. s .. " or learning path" .. s)
    ctx.warn(
      ("error: %s still has %d open %s: %s"):format(id, n, what, table.concat(res.holding, ", "))
    )
    return 1
  end
  if res.err then
    ctx.warn("error: " .. res.err)
    return 1
  end
  say_closed(ctx, res.plans_closed, res.plan_summaries, res.projects)
  say_milestones(ctx, res.milestones_reached)
  return 0
end

commands["plan-close"] = function(ctx)
  return close_by_hand(ctx, "plan")
end

commands["project-close"] = function(ctx)
  return close_by_hand(ctx, "project")
end

commands["next"] = function(ctx)
  local area, ok = area_arg(ctx, "next")
  if not ok then
    return 2
  end
  local count = 3
  if ctx.args.opt.n then
    local n, nerr = to_int(ctx.args.opt.n --[[@as string]], "--n")
    if not n or n < 1 then
      ctx.warn("error: " .. (nerr or "--n must be at least 1"))
      return 2
    end
    count = n
  end
  local actor = ctx.args.opt.actor --[[@as string|nil]]
  if actor and not (model.is_actor(actor) or actor == "none") then
    ctx.warn("error: unknown actor in --actor: " .. actor .. " (expected cdx, me, pair or none)")
    return 2
  end
  local format = ctx.args.opt.format or "text"
  if format ~= "text" and format ~= "json" then
    ctx.warn("error: --format must be text or json")
    return 2
  end
  if ctx.eo.today ~= nil and not model.is_date(ctx.eo.today) then
    ctx.warn("error: --today must be YYYY-MM-DD, got '" .. tostring(ctx.eo.today) .. "'")
    return 2
  end
  local not_category = nil
  if ctx.args.opt["not-category"] then
    not_category = {}
    for word in tostring(ctx.args.opt["not-category"]):gmatch("[^,]+") do
      local c = vim.trim(word)
      if not model.is_category(c) then
        ctx.warn("error: unknown category in --not-category: " .. c)
        return 2
      end
      not_category[#not_category + 1] = c
    end
  end
  if format == "json" then
    return contract_cli.next_json(ctx, area, count, actor, not_category)
  end
  local pick, err = next_pick.pick_from_vault({
    root = ctx.eo.root,
    today = ctx.eo.today,
    reminders = true,
    area = area,
    actor = actor,
    not_category = not_category,
    n = count - 1,
    by = ctx.args.opt.by --[[@as string|nil]],
  })
  if not pick then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  for _, line in ipairs(plan_view.next_lines(pick)) do
    ctx.say(line)
  end
  for _, e in ipairs(pick.incomplete or {}) do
    ctx.warn("warn: cannot read directory " .. e .. " (the answer may be incomplete)")
  end
  return 0
end

---`index [<area>] --staged --check`: whether the staged `ROADMAP/TASKS.md` of `area` (default: of every area with a
---staged change below `ROADMAP/`) is the one the staged tasks render to. Writes and stages nothing; one line `stale`
---per area that is not, with what to type, and exit 1. It reads only those areas, so it is fast enough for the
---vault's pre-commit hook (`tasks hook install`).
---@param ctx table
---@param area string|nil
---@return integer
local function staged_check(ctx, area)
  local root = ctx.eo.root
  local areas = { area }
  if not area then
    local found, err = index.staged_areas({ root = root })
    if not found then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    areas = found
  end
  local stale = {}
  for _, name in ipairs(areas) do
    local res, err = index.stage_area(name, { root = root, check = true })
    if not res then
      ctx.warn("error: " .. name .. ": " .. tostring(err))
      return 1
    end
    if res.action == "stale" then
      stale[#stale + 1] = name
      ctx.say(
        ("stale\t%s\t%d open\t%s (%s)"):format(res.area, res.open, res.path, tostring(res.reason))
      )
    end
  end
  if #stale == 0 then
    ctx.say(("index --staged --check: %d area(s) up to date"):format(#areas))
    return 0
  end
  ctx.warn("the staged index does not match the staged task files; to fix, from the vault root:")
  for _, name in ipairs(stale) do
    ctx.warn("  tasks index " .. name .. " --staged")
  end
  ctx.warn(
    "  then commit the staging area as it is (`git commit -m ...`, no paths: `git commit -- <paths>` takes the"
      .. " tree's TASKS.md, not the staged one)"
  )
  ctx.warn(
    "  or, in a vault shared by several sessions: `tasks commit <your paths>... --message=<text>`"
      .. " (commits them with an index generated from that commit)"
  )
  return 1
end

function commands.index(ctx)
  local args, eo = ctx.args, ctx.eo
  if #args.pos > 1 then
    ctx.warn("error: index takes at most one area")
    return 2
  end
  if args.opt.staged and args.opt.check then
    if args.opt.all then
      ctx.warn("error: index --staged --check takes an area or none, and no --all")
      return 2
    end
    return staged_check(ctx, args.pos[1])
  end
  if args.opt.staged then
    if not args.pos[1] or args.opt.all then
      ctx.warn("error: index --staged takes one area, and no --all (--check only reports)")
      return 2
    end
    local res, err = index.stage_area(args.pos[1], { root = eo.root })
    if not res then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    ctx.say(("%s	%s	%d open	%s (staged)"):format(res.action, res.area, res.open, res.path))
    -- The index is built from these as well: a file that is not the caller's (an autostash that hit a conflict
    -- stages the whole tree) must be seen before the commit, not after the push.
    for _, path in ipairs(res.staged or {}) do
      ctx.say("staged	" .. path)
    end
    if res.staged and #res.staged > 0 then
      ctx.warn(
        "note: the index counts the staged files above; one that is not yours: `git restore --staged <path>`, then run again"
      )
    end
    if res.tree_differs then
      ctx.warn(
        (
          "note: the working tree keeps its %s, so `check` (it reads the tree) still calls it index-stale; the commit"
          .. " holds the staged one. Do not `git add` it now: that stages the tree's old index over this one."
          .. " In a checkout of your own: after the commit, `git checkout -- %s`"
        ):format(res.path, res.path)
      )
    end
    return 0
  end
  local opts = { root = eo.root, check = args.opt.check == true }
  local results, errors
  local whole_vault = not (args.pos[1] and not args.opt.all)
  if args.pos[1] and not args.opt.all then
    local res, err = index.write_area(args.pos[1], opts)
    results, errors = res and { res } or {}, err and { args.pos[1] .. ": " .. err } or {}
  else
    results, errors = index.write_all(opts)
  end
  if not results then
    ctx.warn("error: " .. tostring(errors[1]))
    return 1
  end

  local counts = { written = 0, removed = 0, unchanged = 0, stale = 0 }
  for _, r in ipairs(results) do
    counts[r.action] = counts[r.action] + 1
    if r.action ~= "unchanged" then
      local reason = r.reason and (" (" .. r.reason .. ")") or ""
      ctx.say(("%s\t%s\t%d open\t%s%s"):format(r.action, r.area, r.open, r.path, reason))
    end
  end
  for _, e in ipairs(errors) do
    ctx.warn("error: " .. e)
  end
  if opts.check then
    ctx.say(
      ("index --check: %d area(s), %d stale, %d error(s)"):format(#results, counts.stale, #errors)
    )
    return (counts.stale > 0 or #errors > 0) and 1 or 0
  end
  ctx.say(
    ("index: %d area(s), %d written, %d removed, %d unchanged, %d error(s)"):format(
      #results,
      counts.written,
      counts.removed,
      counts.unchanged,
      #errors
    )
  )
  -- A run over the whole vault is the moment the series of the figures grows by today (the count reads the vault
  -- once more, through the parse cache the index just filled).
  -- Only a vault that keeps a series (the folder is there), and never the reason for the index to fail.
  local root = vault.root(eo)
  if whole_vault and not args.opt["no-history"] and root and history.exists(root) then
    local recorded, rerr
    local view, verr = contract.view({ root = root })
    if view then
      recorded, rerr = history.record(view, { today = eo.today })
    end
    if recorded and recorded.rows > 0 then
      ctx.say(("history\t%d row(s)\t%s"):format(recorded.rows, recorded.file))
    elseif not recorded then
      ctx.warn("warn: history not recorded: " .. contract.redact(root, tostring(verr or rerr)))
    end
  end
  return #errors > 0 and 1 or 0
end

---@param ctx Tasks.CliCtx
---@param res table
local function report_index(ctx, res)
  if res.index_err then
    ctx.warn("warn: index not updated: " .. res.index_err)
  elseif res.index and res.index.action ~= "unchanged" then
    ctx.say(("index\t%s\t%s"):format(res.index.action, res.index.path))
  end
end

function commands.new(ctx)
  local args, eo = ctx.args, ctx.eo
  local opt = args.opt
  local area = args.pos[1]
  local title = args.pos[2] or opt.title
  if not area or not title or #args.pos > 2 then
    ctx.warn('error: usage: new <area> "<title>" [options]')
    return 2
  end
  local new_opts = {
    root = eo.root,
    today = eo.today,
    title = title,
    kind = opt.kind --[[@as string|nil]],
    prio = opt.prio --[[@as string|nil]],
    effort = opt.effort --[[@as string|nil]],
    tags = opt.tags --[[@as string|nil]],
    category = opt.category --[[@as string|nil]],
    scope = opt.scope --[[@as string|nil]],
    severity = opt.severity --[[@as string|nil]],
    outcome = opt.outcome --[[@as string|nil]],
    outcome_reason = opt.reason --[[@as string|nil]],
    value = opt.value --[[@as string|nil]],
    xp = opt.xp --[[@as string|nil]],
    actor = opt.actor --[[@as string|nil]],
    after = opt.after --[[@as string|nil]],
    order = opt.order --[[@as string|nil]],
    plan = opt.plan --[[@as string|nil]],
    project = opt.project --[[@as string|nil]],
    phase = opt.phase --[[@as string|nil]],
    refs = opt.refs --[[@as string|nil]],
    web_links = opt.links --[[@as string|nil]],
    icon = opt.icon --[[@as string|nil]],
    cover = opt.cover --[[@as string|nil]],
    due = opt.due --[[@as string|nil]],
    start = opt.start --[[@as string|nil]],
    created = opt.created --[[@as string|nil]],
    repeat_every = opt["repeat"] --[[@as string|nil]],
    repeat_from = opt["repeat-from"] --[[@as string|nil]],
    repeat_after = opt["repeat-after"] --[[@as string|nil]],
    lang = opt.lang --[[@as "de"|"en"|nil]],
    summary = opt.summary --[[@as string|nil]],
    slug = opt.slug --[[@as string|nil]],
    status = opt.status --[[@as string|nil]],
    waits_for = opt["waits-for"] --[[@as string|nil]],
    folder = opt.folder == true,
    index = not opt["no-index"],
  }
  -- `a,b`: one task in each area, the same text in all; every area is tried as a dry run first, so a bad one
  -- stops the whole thing before anything is written
  local made, merr = mutate.new_many(area, new_opts)
  if not made then
    ctx.warn("error: " .. tostring(merr))
    return 1
  end
  for _, res in ipairs(made) do
    ctx.say(("created\t%s\t%s"):format(res.id, res.path))
    if res.ambiguous then
      ctx.warn("warn: " .. require("tasks_nvim.wikilinks").ambiguity_message(res.ambiguous))
    end
    -- the file is written as asked (a plan may follow); a relation that names nothing is a word, as `check` would say
    if new_opts.plan or new_opts.project or new_opts.phase then
      local problems = require("tasks_nvim.edges").validate(res.id, {
        plan = new_opts.plan,
        project = new_opts.project,
        phase = new_opts.phase,
      }, { root = eo.root })
      for _, problem in ipairs(problems or {}) do
        ctx.warn("warn: " .. res.id .. ": " .. problem.message)
      end
    end
    report_index(ctx, res)
  end
  return 0
end

---The kind of the open plan, project or learning path file an id names (`nil`: none; an open task is looked for
---first by the caller).
---@param id string
---@param root? string
---@return "plan"|"project"|"path"|nil
local function file_kind_of(id, root)
  if require("tasks_nvim.paths").find(id, { root = root }) then
    return "path"
  elseif require("tasks_nvim.plans").find(id, { root = root }) then
    return "plan"
  elseif require("tasks_nvim.projects").find(id, { root = root }) then
    return "project"
  end
  return nil
end

---`set` on a plan, project or learning path file (`plans.set` with `kind`, the same as `plan_set`, `project_set` and
---`path_set` of the write door): its frontmatter keys (`plans.SET_KEYS`), an empty value removes one.
---@param ctx Tasks.CliCtx
---@param id string
---@param patch table<string, any>
---@param kind "plan"|"project"|"path"
---@return integer code
local function set_file(ctx, id, patch, kind)
  local file_patch = {}
  for key, value in pairs(patch) do
    file_patch[key] = value == mutate.REMOVE and vim.NIL or value
  end
  local res, err, info = require("tasks_nvim.plans").set(
    id,
    file_patch,
    { root = ctx.eo.root, today = ctx.eo.today, kind = kind }
  )
  if not res then
    ctx.warn("error: " .. tostring(err))
    return (info and info.code == "invalid_argument") and 2 or 1
  end
  ctx.say(("set\t%s\t%s\t%s"):format(res.id, res.changed and "changed" or "unchanged", res.path))
  return 0
end

function commands.set(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos < 2 then
    ctx.warn("error: usage: set <area>/<slug> key=value [key=value ...]")
    return 2
  end
  local patch = {}
  for i = 2, #args.pos do
    local key, value = args.pos[i]:match("^([%w_]+)=(.*)$")
    if not key then
      ctx.warn("error: expected key=value, got " .. args.pos[i])
      return 2
    end
    patch[key] = value == "" and mutate.REMOVE or value
  end
  -- an id that names no open task may name a plan, project or learning path file: its frontmatter is set there
  if not scan.find(id, { root = eo.root }) then
    local kind = file_kind_of(id, eo.root)
    if kind then
      return set_file(ctx, id, patch, kind)
    end
  end
  if patch.status == "doing" then
    -- A guard rail, not a lock (nothing is refused because of plan or meta fields): a headless session that
    -- starts a task marked for the human gets told.
    local current = scan.find(id, { root = eo.root })
    if current and model.actor(current) == "me" then
      ctx.warn(
        ("warn: %s is for you (actor: me); a headless session should not start it"):format(id)
      )
    end
  end
  local co = claim_opts(args.opt)
  local before = co.force and claims.read(vault.root(eo) or "", id) or nil
  local res, err = mutate.set(
    id,
    patch,
    vim.tbl_extend(
      "force",
      { root = eo.root, today = eo.today, index = not args.opt["no-index"] },
      co
    )
  )
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  claims.record_override(
    id,
    before,
    vim.tbl_extend("force", { root = eo.root, today = eo.today }, co)
  )
  ctx.say(("set\t%s\t%s\t%s"):format(res.id, res.changed and "changed" or "unchanged", res.path))
  if res.point_err then
    ctx.warn("note: " .. res.point_err)
  end
  report_index(ctx, res)
  return 0
end

---`waits [<area>] [--format=tsv|json]`: what the parked tasks wait for.
function commands.waits(ctx)
  local format = ctx.args.opt.format or "tsv"
  if format ~= "tsv" and format ~= "json" then
    ctx.warn("error: --format must be tsv or json")
    return 2
  end
  local area, area_ok = area_arg(ctx, "waits")
  if not area_ok then
    return 2
  end
  if format == "json" then
    return contract_cli.waits_json(ctx, area)
  end
  local open, skipped, errors = scan.open_tasks({ root = ctx.eo.root, area = area })
  if not open then
    ctx.warn("error: " .. tostring(skipped))
    return 1
  end
  local sum = waits.summary(open)
  for _, k in ipairs(sum.keys) do
    ctx.say(("%s\t%d\t%s"):format(k.key, k.count, fsio.clean(table.concat(k.areas, ","))))
  end
  ctx.say(("parked without a reason: %d"):format(sum.without))
  if sum.invalid > 0 then
    ctx.say(("parked with an invalid waits_for: %d (see check)"):format(sum.invalid))
  end
  ctx.say(("parked: %d"):format(sum.parked))
  if type(errors) == "table" and #errors > 0 then
    for _, e in ipairs(errors) do
      ctx.warn("warn: cannot read directory " .. e)
    end
    return 1
  end
  return 0
end

---`release <key> [--dry-run]`: every parked task that waits for the key goes back to `open`.
function commands.release(ctx)
  local args, eo = ctx.args, ctx.eo
  local key = args.pos[1]
  if not key or #args.pos > 1 then
    ctx.warn("error: usage: release <key> [--dry-run]   (the keys: `waits`)")
    return 2
  end
  if not model.is_waits_for(key) then
    ctx.warn("error: " .. model.waits_for_error(key))
    return 2
  end
  local res, err = require("tasks_nvim.batch").release(key, {
    root = eo.root,
    today = eo.today,
    index = not args.opt["no-index"],
    dry_run = args.opt["dry-run"] == true,
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  for _, e in ipairs(res.incomplete) do
    ctx.warn("warn: cannot read directory " .. e .. " (tasks in it were not looked at)")
  end
  if #res.ids == 0 then
    ctx.warn(("error: no parked task waits for '%s' (the keys in use: `waits`)"):format(key))
    return 1
  end
  if res.dry_run then
    for _, id in ipairs(res.ids) do
      ctx.say("would-release\t" .. fsio.clean(id))
    end
    ctx.say(("release\t%s\tdry-run\t%d task(s); nothing written"):format(key, #res.ids))
    return #res.incomplete > 0 and 1 or 0
  end
  local done = assert(res.result)
  for _, changed in ipairs(done.changed) do
    ctx.say("released\t" .. fsio.clean(changed.id))
  end
  for _, id in ipairs(done.unchanged) do
    ctx.say("unchanged\t" .. fsio.clean(id))
  end
  for _, f in ipairs(done.failed) do
    ctx.warn(("error: %s: %s"):format(f.id, f.err))
  end
  for _, e in ipairs(done.index_errors) do
    ctx.warn("warn: index " .. e)
  end
  ctx.say(("release\t%s\t%d released, %d failed"):format(key, #done.changed, #done.failed))
  return (#done.failed > 0 or #res.incomplete > 0) and 1 or 0
end

---`<container>#<ref>` of `promote` and `unpromote`: the container id and the key (or `n` / `#n`, a position).
---@param arg string|nil
---@return string|nil container
---@return string|integer|nil ref
local function point_arg(arg)
  local container, ref = (arg or ""):match("^([^#%s]+/[^#%s]+)#(%S+)$")
  if not container then
    return nil
  end
  return container, tonumber(ref) or ref
end

function commands.promote(ctx)
  local args, eo = ctx.args, ctx.eo
  local container, ref = point_arg(args.pos[1])
  if not container or #args.pos > 1 then
    ctx.warn(
      "error: usage: promote <area>/<slug>#<key|n> [--area=a] [--title=t] [--actor=cdx|me|pair] [--tags=a,b] [--after=id,id] [--effort=XS..XL] [--dry-run] [--no-index]"
    )
    return 2
  end
  local res, err = require("tasks_nvim.promote").promote(container, ref, {
    root = eo.root,
    today = eo.today,
    area = args.opt.area --[[@as string|nil]],
    title = args.opt.title --[[@as string|nil]],
    actor = args.opt.actor --[[@as string|nil]],
    tags = args.opt.tags --[[@as string|nil]],
    after = args.opt.after --[[@as string|nil]],
    effort = args.opt.effort --[[@as string|nil]],
    dry_run = args.opt["dry-run"] == true,
    index = not args.opt["no-index"],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(
    ("%s\t%s\t%s\t%d line(s) moved"):format(
      res.dry_run and "would-promote" or "promoted",
      res.point,
      res.id,
      res.moved
    )
  )
  return 0
end

function commands.unpromote(ctx)
  local args, eo = ctx.args, ctx.eo
  local container, ref = point_arg(args.pos[1])
  if not container or #args.pos > 1 then
    ctx.warn("error: usage: unpromote <area>/<slug>#<key|n> [--dry-run]")
    return 2
  end
  local res, err = require("tasks_nvim.promote").unpromote(container, ref, {
    root = eo.root,
    today = eo.today,
    dry_run = args.opt["dry-run"] == true,
    index = not args.opt["no-index"],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(
    ("%s\t%s#%s\t%s"):format(
      res.dry_run and "would-unpromote" or "unpromoted",
      res.container,
      tostring(res.key),
      res.id
    )
  )
  return 0
end

function commands.answer(ctx)
  local args, eo = ctx.args, ctx.eo
  local id, question, choice = args.pos[1], args.pos[2], args.pos[3]
  if not id or not question or not choice or #args.pos > 3 then
    ctx.warn("error: usage: answer <area>/<slug> <q1|#n> <n|clear>")
    return 2
  end
  local option = choice == "clear" and 0 or tonumber(choice)
  if option == nil or option % 1 ~= 0 or option < 0 then
    ctx.warn("error: the option is a whole number from 1, or `clear`")
    return 2
  end
  local res, err = mutate.edit_text(id, function(text)
    local new_text, info, qerr = questions.answer(text, question, option)
    if not new_text then
      return nil, qerr
    end
    return new_text, nil, { key = info and info.key or question }
  end, { root = eo.root, today = eo.today, index = not args.opt["no-index"] })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(
    ("answer\t%s\t%s\t%s\t%s"):format(
      res.id,
      res.extra and res.extra.key or question,
      choice,
      res.changed and "changed" or "unchanged"
    )
  )
  report_index(ctx, res)
  return 0
end

function commands.migrate_actor(ctx)
  local args, eo = ctx.args, ctx.eo
  local area, area_ok = area_arg(ctx, "migrate-actor")
  if not area_ok then
    return 2
  end
  local open, skipped, errors = scan.open_tasks({ root = eo.root, area = area })
  if not open then
    ctx.warn("error: " .. tostring(skipped))
    return 1
  end
  local batch = require("tasks_nvim.batch")
  local proposals, left = batch.plan_actor_migration(open)
  for _, p in ipairs(proposals) do
    ctx.say(
      ("%s\t%s\t%s\t%s"):format(args.opt.write and "set" or "propose", p.id, p.actor, p.reason)
    )
  end
  ctx.warn(
    ("%d proposed, %d left empty (of %d open)%s"):format(
      #proposals,
      left,
      #open,
      args.opt.write and "" or "; dry run, pass --write to apply"
    )
  )
  if errors and #errors > 0 then
    ctx.warn("warn: the result is incomplete, could not read: " .. table.concat(errors, ", "))
  end
  if args.opt.write and #proposals > 0 then
    local res = batch.set_many(
      batch.actor_steps(proposals),
      { root = eo.root, today = eo.today, index = not args.opt["no-index"] }
    )
    for _, f in ipairs(res.failed) do
      ctx.warn(("error: %s: %s"):format(f.id, f.err))
    end
    for _, e in ipairs(res.index_errors) do
      ctx.warn("warn: index " .. e)
    end
    return #res.failed > 0 and 1 or 0
  end
  return 0
end
commands["migrate-actor"] = commands.migrate_actor

---After a `done`: the paths it wrote in the vault, as one line `commit-paths` to hand to `tasks commit` (TASKS-08), or
---with `--commit` committed at once from a staging area of their own (other sessions' files stay out). The generated
---index files are not in the list: `commit` renders them.
---@param ctx Tasks.CliCtx
---@param vcommit table  `tasks_nvim.vault_commit`
---@param before table<string, string>|nil  `snapshot` taken before the finish
---@return integer code
local function done_commit(ctx, vcommit, before)
  local args = ctx.args
  if not before then
    if args.opt.commit == true then
      ctx.warn("error: --commit: the vault is no git repository, nothing was committed")
      return 1
    end
    return 0
  end
  local after = vcommit.snapshot({ root = ctx.eo.root })
  local paths = after and vcommit.changed_since(before, after) or {}
  if #paths == 0 then
    return 0
  end
  if args.opt.commit ~= true then
    ctx.say("commit-paths	" .. table.concat(paths, " "))
    return 0
  end
  local id = args.pos[1]
  local res, err = vcommit.commit(paths, {
    root = ctx.eo.root,
    message = args.opt["commit-message"] or ("done: " .. id),
  })
  if not res then
    ctx.warn("error: done stands, but the commit failed: " .. tostring(err))
    ctx.say("commit-paths	" .. table.concat(paths, " "))
    return 1
  end
  ctx.say(("committed	%s	%d path(s)"):format(res.commit:sub(1, 9), #res.paths))
  if res.settle_error then
    ctx.warn(
      "warn: the shared staging area still holds the old version of the committed paths: "
        .. res.settle_error
    )
  end
  return 0
end

function commands.done(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 then
    ctx.warn(
      "error: usage: done <area>/<slug> [--commits=repo@sha,...] [--done-in=text] [--date=YYYY-MM-DD] [--remind=7d|YYYY-MM-DD] [--outcome=learned|seen|not-applicable] [--reason=text] [--ci=pending|green|red] [--commit [--commit-message=text]]"
    )
    return 2
  end
  if args.opt["commit-message"] ~= nil and args.opt.commit ~= true then
    ctx.warn("error: --commit-message needs --commit")
    return 2
  end
  -- What `done` wrote in the vault is what differs afterwards from what was there before.
  local vcommit = require("tasks_nvim.vault_commit")
  local before = vcommit.snapshot({ root = eo.root })
  local flow, err = done_flow.run(id, {
    root = eo.root,
    today = eo.today,
    done_in = args.opt["done-in"] --[[@as string|nil]],
    commits = args.opt.commits --[[@as string|nil]],
    outcome = args.opt.outcome --[[@as string|nil]],
    outcome_reason = args.opt.reason --[[@as string|nil]],
    ci = args.opt.ci --[[@as string|nil]],
    ack = args.opt.ack == true,
    remind = args.opt.remind
        and (args.opt.remind:match("^%d+[dw]$") and "+" .. args.opt.remind or args.opt.remind)
      or nil,
    date = args.opt.date --[[@as string|nil]],
    index = not args.opt["no-index"],
    last = args.opt.last == true,
    by = args.opt.by --[[@as string|nil]],
    force = args.opt.force == true,
    note = args.opt.note --[[@as string|nil]],
  })
  if not flow then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  local res = flow.done
  if res.already then
    ctx.say(("already\t%s\t%s"):format(res.id, res.to))
    return 0
  end
  ctx.say(("done\t%s\t%s"):format(res.id, res.to))
  if res.readme == "missing" then
    ctx.warn("warn: Backlog/README.md does not exist; no index row added")
  end
  if flow.steps_ticked > 0 then
    ctx.say(("steps\t%s\t%d"):format(res.id, flow.steps_ticked))
  end
  if flow.next_round then
    ctx.say(("next-round\t%s\t%s"):format(flow.next_round.id, flow.next_round.due))
  end
  if flow.routine_ended then
    ctx.say(("routine-ended\t%s\tthe last round of repeat"):format(id))
  end
  for _, r in ipairs(flow.routines_started or {}) do
    ctx.say(("routine-started\t%s\t%s\tafter %s"):format(r.id, r.due, r.after))
  end
  for _, plan_id in ipairs(flow.plans_closed) do
    ctx.say(
      ("plan-closed\t%s\t%s"):format(
        plan_id,
        plan_view.plan_closed_text(plan_id, flow.plan_summaries[plan_id])
      )
    )
  end
  for _, project_id in ipairs(flow.projects_closed) do
    ctx.say(
      ("project-closed\t%s\t%s"):format(
        project_id,
        plan_view.project_closed_text(project_id, flow.project_summaries[project_id])
      )
    )
  end
  say_milestones(ctx, flow.milestones_reached, flow.milestones_reopened)
  for _, doc in ipairs(flow.docs_refreshed) do
    ctx.say(("refreshed\t%s"):format(doc))
  end
  for _, note in ipairs(flow.notes) do
    ctx.warn(("warn: %s: %s"):format(res.id, note))
  end
  if args.opt.unblock and flow.next and #flow.next.freed_blocked > 0 then
    -- Never without being asked: only the tasks that waited on exactly this one and still read `blocked`.
    local steps = {}
    for _, task_id in ipairs(flow.next.freed_blocked) do
      steps[#steps + 1] = { id = task_id, patch = { status = "open" } }
    end
    local unblocked = require("tasks_nvim.batch").set_many(
      steps,
      { root = eo.root, today = eo.today, index = not args.opt["no-index"] }
    )
    for _, changed in ipairs(unblocked.changed) do
      ctx.say(("unblocked\t%s"):format(fsio.clean(changed.id)))
    end
    for _, f in ipairs(unblocked.failed) do
      ctx.warn(("warn: %s: %s"):format(f.id, f.err))
    end
    if #unblocked.changed > 0 and not args.opt["no-next"] then
      -- The advice below was worked out while the freed tasks still read `blocked`: they rank first once open.
      local pick = next_pick.pick_from_vault({
        root = eo.root,
        done = { id = res.id, area = flow.done.area },
      })
      if pick then
        flow.next = pick
      end
    end
  end
  if flow.next and not args.opt["no-next"] then
    for _, line in ipairs(plan_view.next_lines(flow.next)) do
      ctx.say(line)
    end
    for _, e in ipairs(flow.next.incomplete or {}) do
      ctx.warn("warn: cannot read directory " .. e .. " (the answer may be incomplete)")
    end
  end
  report_index(ctx, res)
  return done_commit(ctx, vcommit, before)
end

---The id `reopen` is given, as an id: `<area>/<slug>`, also the name of the finished file (`<area>/2026-11-18_<slug>`,
---with or without `.md`) or its path below the vault (`<area>/Backlog/TASKS/2026-11-18_<slug>.md`).
---@param arg string
---@return string id
function M.reopen_id(arg)
  local norm = arg:gsub("\\", "/")
  local area, file = norm:match("^([^/]+)/Backlog/[^/]+/([^/]+)$")
  if not area then
    area, file = norm:match("^([^/]+)/([^/]+)$")
  end
  if not area then
    return arg
  end
  return area .. "/" .. model.slug_of(file, "backlog")
end

---`tasks reopen <id> [--status=open|doing|blocked|parked|decision]`: a finished task back to `ROADMAP/tasks`, through
---the write door (`reopen` of `tasks-ops/1`): the index of its area and the milestones are brought in line there.
---@param ctx Tasks.CliCtx
---@return integer code
function commands.reopen(ctx)
  local args, eo = ctx.args, ctx.eo
  local status = args.opt.status --[[@as string|nil]]
  if not args.pos[1] or #args.pos > 1 then
    ctx.warn(
      ("error: usage: reopen <area>/<slug> [--status=%s]"):format(
        table.concat(model.OPEN_STATUSES, "|")
      )
    )
    return 2
  end
  if status ~= nil and not model.is_open_status(status) then
    ctx.warn(
      ("error: unknown status '%s' (expected %s)"):format(
        status,
        table.concat(model.OPEN_STATUSES, ", ")
      )
    )
    return 2
  end
  local id = M.reopen_id(args.pos[1])
  local doc, err = require("tasks_nvim.ops").run(
    { ops = { { op = "reopen", id = id, status = status } } },
    { root = eo.root, today = eo.today }
  )
  if not doc then
    ctx.warn("error: " .. tostring(type(err) == "table" and err.message or err))
    return 1
  end
  local entry = doc.results[1]
  if not entry.ok then
    ctx.warn(("error: %s (%s)"):format(tostring(entry.error.message), tostring(entry.error.code)))
    return 1
  end
  if entry.outcome == "unchanged" then
    ctx.say(("already-open\t%s"):format(fsio.clean(entry.id)))
    return 0
  end
  ctx.say(("reopened\t%s\t%s"):format(fsio.clean(entry.id), fsio.clean(entry.file or "")))
  say_milestones(ctx, entry.milestones_reached, entry.milestones_reopened)
  for _, note in ipairs(entry.notes or {}) do
    ctx.warn(("warn: %s: %s"):format(entry.id, note))
  end
  -- relative to the vault, as `file` is: the root may come from $TASKS_VAULT, `eo.root` is nil then
  local area = entry.id:match("^([^/]+)/")
  if entry.index and entry.index.action == "error" then
    ctx.warn("warn: index not updated: " .. tostring(entry.index.error))
  elseif entry.index and entry.index.action ~= "unchanged" then
    ctx.say(("index\t%s\t%s/ROADMAP/TASKS.md"):format(entry.index.action, fsio.clean(area)))
  end
  return 0
end

function commands.attach(ctx)
  local args, eo = ctx.args, ctx.eo
  local id, file = args.pos[1], args.pos[2]
  local from_clipboard, from_latest = args.opt.clipboard, args.opt.latest
  local sourced = from_clipboard or from_latest
  if from_clipboard and from_latest then
    ctx.warn("error: --clipboard and --latest exclude each other")
    return 2
  end
  if not id or (sourced and file) or (not sourced and not file) or #args.pos > 2 then
    ctx.warn(
      "error: usage: attach <area>/<slug> <file> [--name=n] [--kind=video|image|screenshot]  |  attach <area>/<slug> --clipboard|--latest[=<folder>]"
    )
    return 2
  end
  local kind = args.opt.kind --[[@as string|nil]]
  if kind ~= nil and not mutate.asset_dir(kind) then
    ctx.warn("error: --kind takes " .. mutate.ASSET_KINDS_TEXT)
    return 2
  end
  local res, err, too_old
  if sourced then
    res, err, too_old =
      require("tasks_nvim.attach_source").attach(id, from_clipboard and "clipboard" or "latest", {
        root = eo.root,
        today = eo.today,
        name = args.opt.name --[[@as string|nil]],
        kind = kind,
        dir = type(from_latest) == "string" and from_latest or nil,
        index = not args.opt["no-index"],
        by = args.opt.by --[[@as string|nil]],
        force = args.opt.force == true,
        note = args.opt.note --[[@as string|nil]],
      })
    if not res and too_old then
      err = tostring(err) .. " (pass the file, or raise attach.max_age_s)"
    end
  else
    res, err = mutate.attach(
      id,
      file,
      vim.tbl_extend("force", {
        root = eo.root,
        today = eo.today,
        name = args.opt.name --[[@as string|nil]],
        kind = kind,
        index = not args.opt["no-index"],
      }, claim_opts(args.opt))
    )
  end
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("attached\t%s\t%s\t%s"):format(res.id, res.rel, res.link))
  if res.updated_err then
    ctx.warn("warning: the asset is attached, but `updated` was not changed: " .. res.updated_err)
  end
  if res.folderized then
    ctx.say(("folderized\t%s\t%s"):format(res.id, res.path))
  end
  report_index(ctx, res)
  return 0
end

---`intent <file|-> [--yes]`: take an intent `wkd-intent/1`. Without `--yes` nothing is written.
function commands.intent(ctx)
  local args, eo = ctx.args, ctx.eo
  local source = args.pos[1]
  if not source or #args.pos > 1 then
    ctx.warn("error: usage: intent <file|-> [--yes] [--lang=de|en]")
    return 2
  end
  local intent = require("tasks_nvim.intent")
  local text
  if source == "-" then
    text = ((ctx.io and ctx.io.stdin) or io.stdin):read(intent.MAX_BYTES + 1)
  else
    local handle, oerr = io.open(source, "rb")
    if not handle then
      ctx.warn("error: cannot read " .. source .. ": " .. tostring(oerr))
      return 1
    end
    -- one byte more than the limit: enough to see that it is too big, never the whole of a huge file
    text = handle:read(intent.MAX_BYTES + 1)
    handle:close()
  end
  local res, err = intent.run(text or "", {
    root = eo.root,
    today = eo.today,
    yes = args.opt.yes == true,
    lang = args.opt.lang --[[@as "de"|"en"|nil]],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  if res.outcome == "would_create" then
    ctx.say(("would_create\t%s\t%s"):format(res.area, fsio.clean(res.title)))
  elseif res.outcome == "created" then
    ctx.say(("created\t%s"):format(res.id))
  elseif res.outcome == "exists" or res.outcome == "shown" then
    ctx.say(("%s\t%s\t%s\t%s"):format(res.outcome, res.id, res.status, res.location))
  else
    ctx.say(("%s\t%s"):format(res.outcome, res.id))
  end
  return 0
end

---`claim <id> [--by=] [--for=] [--renew] [--force --note=]`: reserve a task while somebody works on it.
function commands.claim(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 then
    ctx.warn(
      "error: usage: claim <area>/<slug> [--by=<name>] [--for=4h] [--renew] [--force --note=<why>]"
    )
    return 2
  end
  local res, err = claims.acquire(id, {
    root = eo.root,
    today = eo.today,
    by = args.opt.by --[[@as string|nil]],
    for_ = args.opt["for"] --[[@as string|nil]],
    renew = args.opt.renew == true,
    force = args.opt.force == true,
    note = args.opt.note --[[@as string|nil]],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  if res.taken_over then
    ctx.warn(
      ("warn: took over the claim of %s (%s)"):format(
        res.taken_over.by,
        claims.describe(res.taken_over)
      )
    )
  end
  ctx.say(
    ("%s\t%s\t%s\t%s"):format(
      res.renewed and "renewed" or "claimed",
      id,
      res.claim.by,
      res.claim.until_
    )
  )
  return 0
end

---`unclaim <id> [--by=] [--status=] [--force --note=]`: give a task back (the name of the verb: `release` is taken by
---the parked tasks of `waits_for`).
function commands.unclaim(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 then
    ctx.warn(
      "error: usage: unclaim <area>/<slug> [--by=<name>] [--status=open|parked|decision] [--force --note=<why>]"
    )
    return 2
  end
  local res, err = claims.release(id, {
    root = eo.root,
    today = eo.today,
    by = args.opt.by --[[@as string|nil]],
    force = args.opt.force == true,
    note = args.opt.note --[[@as string|nil]],
    status = args.opt.status --[[@as string|nil]],
  })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("unclaimed\t%s\t%s"):format(id, res.status or "-"))
  return 0
end

function commands.folderize(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 then
    ctx.warn("error: usage: folderize <area>/<slug>")
    return 2
  end
  local res, err = mutate.folderize(
    id,
    vim.tbl_extend(
      "force",
      { root = eo.root, index = not args.opt["no-index"] },
      claim_opts(args.opt)
    )
  )
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  ctx.say(("%s\t%s\t%s"):format(res.changed and "folderized" or "unchanged", res.id, res.path))
  report_index(ctx, res)
  return 0
end

---`sheet-run <area>/<slug> [--testing-cli=<path>] [--dry-run]`: run the task's test sheets now through testing.nvim's
---`testing sheets run`, which writes their state into the task; its output and exit code are this command's.
commands["sheet-run"] = function(ctx)
  local args, eo = ctx.args, ctx.eo
  local id = args.pos[1]
  if not id or #args.pos > 1 or not id:match("^[%w_][^/]*/[^/]+$") or not vault.parse_id(id) then
    ctx.warn("error: usage: sheet-run <area>/<slug> [--testing-cli=<path>] [--dry-run]")
    return 2
  end
  local root, rerr = vault.root({ root = eo.root })
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local res = require("tasks_nvim.sheet_run").run(id, {
    vault = root,
    cli = args.opt["testing-cli"] --[[@as string|nil]],
    dry_run = args.opt["dry-run"] == true,
  })
  for _, line in ipairs(res.lines) do
    ctx.say(line)
  end
  if res.code ~= 0 then
    ctx.warn("sheet-run: " .. res.summary)
  end
  return res.code
end

---`sheet-ai draft|explain <id>` prints the hand-over document for an AI (testing.nvim's `testing sheets prompt`);
---`sheet-ai accept|bug <id> --from=<answer file>` shows the sheet or bug task of the AI's answer and writes it only with
---`--yes` (accept: testing.nvim's `testing sheets accept`, which writes only a sheet that loads).
commands["sheet-ai"] = function(ctx)
  local args, eo = ctx.args, ctx.eo
  local step, id = args.pos[1], args.pos[2]
  local sr = require("tasks_nvim.sheet_run")
  local usage =
    "error: usage: sheet-ai draft|explain <area>/<slug> | sheet-ai accept|bug <area>/<slug> --from=<file> [--yes]"
  if
    #args.pos ~= 2
    or not (sr.AI[step] or step == "bug")
    or not id:match("^[%w_][^/]*/[^/]+$")
    or ((step == "accept" or step == "bug") and not args.opt.from)
  then
    ctx.warn(usage)
    return 2
  end
  local root, rerr = vault.root({ root = eo.root })
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local opts = {
    vault = root,
    cli = args.opt["testing-cli"] --[[@as string|nil]],
  }
  if step == "draft" or step == "explain" then
    local res = sr.ai(step, id, opts)
    if res.code ~= 0 then
      ctx.warn("sheet-ai: " .. res.summary)
      return res.code
    end
    if (res.stdout or "") == "" then
      ctx.warn("sheet-ai: " .. (res.lines[1] or "nothing to hand over"))
      return 0
    end
    ctx.out(res.stdout)
    return 0
  end
  local from = tostring(args.opt.from)
  local f = io.open(from, "rb")
  if not f then
    ctx.warn("error: cannot read " .. from)
    return 2
  end
  local answer = f:read("*a")
  f:close()
  if step == "bug" then
    local proposal = sr.task_block(answer)
    if not proposal then
      ctx.warn("error: no ```task block (title:, summary:) in " .. from)
      return 1
    end
    if not args.opt.yes then
      ctx.say(("would create\t%s\tbug\t%s"):format(id:match("^[^/]+"), proposal.title))
      ctx.say("(add --yes to create it)")
      return 0
    end
    local made, merr = sr.create_bug(proposal, id, root)
    if not made then
      ctx.warn("error: " .. tostring(merr))
      return 1
    end
    ctx.say("created\t" .. made.id .. "\t" .. made.path)
    return 0
  end
  local lua = sr.lua_block(answer)
  if not lua then
    ctx.warn("error: no ```lua block in " .. from)
    return 1
  end
  if not args.opt.yes then
    ctx.say("would write the sheet:")
    ctx.out(lua .. "\n")
    ctx.say("(add --yes to write it; testing.nvim writes it only when it loads)")
    return 0
  end
  -- exactly the block shown above goes to testing.nvim, in a file of its own
  opts.from = sr.sheet_file(lua)
  local res = sr.ai("accept", id, opts)
  os.remove(opts.from)
  for _, line in ipairs(res.lines) do
    ctx.say(line)
  end
  if res.code ~= 0 then
    ctx.warn("sheet-ai: " .. sr.accept_reason(res))
  end
  return res.code
end

---`check --sources [<file|dir>]`: the web links of the Quellen tables, asked on purpose (`tasks_nvim.sources`).
---@param ctx Tasks.CliCtx
---@return integer
local function check_sources(ctx)
  local args, eo = ctx.args, ctx.eo
  if #args.pos > 1 or args.opt.all then
    ctx.warn("error: check --sources takes at most one file or folder")
    return 2
  end
  local timeout = args.opt.timeout and tonumber(args.opt.timeout)
  if args.opt.timeout and (not timeout or timeout < 1 or timeout > 120 or timeout % 1 ~= 0) then
    ctx.warn("error: --timeout must be a whole number of seconds from 1 to 120")
    return 2
  end
  local files = {}
  local given = args.pos[1]
  if given then
    local path = fsio.doc_path(given)
    if fsio.is_dir(path) then
      files = vim.fs.find(function(name)
        return name:match("%.md$") ~= nil
      end, { path = path, type = "file", limit = math.huge })
      table.sort(files)
    else
      files = { path }
    end
  else
    local open, err = require("tasks_nvim.paths").all({ root = eo.root })
    if not open then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    for _, f in ipairs(open) do
      files[#files + 1] = f.path
    end
  end
  local sources = require("tasks_nvim.sources")
  local today = eo.today or model.today()
  local counts = { ok = 0, redirected = 0, blocked = 0, dead = 0, error = 0, unreachable = 0 }
  local total, rewritten = 0, 0
  for _, path in ipairs(files) do
    local results, err = sources.check_file(path, {
      timeout = timeout,
      write = args.opt.write == true,
      fix = args.opt.fix == true,
      allow_host_change = args.opt["allow-host-change"] == true,
      today = today,
    })
    if not results then
      ctx.warn("error: " .. tostring(err))
      return 1
    end
    for _, r in ipairs(results) do
      total = total + 1
      counts[r.state] = counts[r.state] + 1
      if r.fixed then
        rewritten = rewritten + 1
        ctx.say(("fixed\t%s:%d\t%s -> %s"):format(path, r.row.line, r.row.url, r.fixed))
      elseif r.kept and args.opt.fix then
        ctx.say(("kept\t%s:%d\t%s\t%s"):format(path, r.row.line, r.row.url, r.kept))
      end
      if r.state ~= "ok" then
        local note = r.state == "redirected" and (" -> " .. r.final)
          or (r.timeout and " (timeout)" or "")
        ctx.say(
          ("%s\t%s:%d\t%s%s\t%s"):format(
            r.state,
            path,
            r.row.line,
            r.code > 0 and tostring(r.code) or "-",
            note,
            r.row.url
          )
        )
      end
    end
  end
  ctx.say(
    ("sources: %d link(s) in %d file(s): %d ok, %d moved, %d blocked (not checkable), %d dead, %d other error, %d no answer%s"):format(
      total,
      #files,
      counts.ok,
      counts.redirected,
      counts.blocked,
      counts.dead,
      counts.error,
      counts.unreachable,
      (args.opt.write and "; column Geprüft written" or "")
        .. (args.opt.fix and ("; %d link(s) rewritten"):format(rewritten) or "")
    )
  )
  return counts.dead > 0 and 1 or 0
end

function commands.check(ctx)
  local args, eo = ctx.args, ctx.eo
  if args.opt.sources then
    return check_sources(ctx)
  elseif args.opt.write or args.opt.timeout or args.opt.fix or args.opt["allow-host-change"] then
    ctx.warn("error: --write, --fix, --allow-host-change and --timeout belong to --sources")
    return 2
  end
  if #args.pos > 1 then
    ctx.warn("error: check takes at most one area")
    return 2
  end
  local area = (not args.opt.all) and args.pos[1] or nil
  local res, err = check.run({ root = eo.root, area = area, today = eo.today })
  if not res then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  local root = assert(vault.root({ root = eo.root }))
  for _, f in ipairs(res.findings) do
    ctx.say(check.format(f, root))
  end
  for _, f in ipairs(res.hints or {}) do
    ctx.say(check.format(f, root))
  end
  ctx.say(
    ("check: %d finding(s) (%d error, %d warning, %d hint) in %d area(s), %d task file(s) read"):format(
      #res.findings,
      res.errors,
      res.warnings,
      #(res.hints or {}),
      res.areas,
      res.tasks
    )
  )
  return res.ok and 0 or 1
end

function commands.ci(ctx)
  if #ctx.args.pos > 0 then
    ctx.warn("error: ci takes no positional argument")
    return 2
  end
  local opt = ctx.args.opt
  local res = require("tasks_nvim.ci").run({
    root = ctx.eo.root,
    strict = opt.strict == true,
    lint = opt["no-lint"] ~= true,
    trust_vault_lint = opt["trust-vault-lint"] == true,
    md_lint = opt["md-lint"] --[[@as string|nil]],
  }, ctx.say)
  return res.code
end

---`agent-brief [--format=md|json] [--by=<name>] [--repo=<dir>]`: the tasks-family brief for an AI agent
---(`tasks_nvim.agent_brief`), built from this file's USAGE so the command reference is never written twice; `--repo`
---adds the checks of that repository. Reads no vault.
commands["agent-brief"] = function(ctx)
  local opt = ctx.args.opt
  if #ctx.args.pos > 0 then
    ctx.warn("error: agent-brief takes no positional argument")
    return 2
  end
  local format = opt.format or "md"
  if format ~= "md" and format ~= "json" then
    ctx.warn("error: --format must be md or json")
    return 2
  end
  local by, berr = agent_brief.check_by(opt.by --[[@as string|nil]])
  if not by then
    ctx.warn("error: " .. berr)
    return 2
  end
  local checks ---@type tasks.AgentBriefChecks|nil
  if opt.repo ~= nil then
    local cerr
    checks, cerr = agent_brief.checks(opt.repo --[[@as string]])
    if not checks then
      ctx.warn("error: " .. cerr)
      return 2
    end
  end
  local brief_opts = { usage = USAGE, by = by, checks = checks }
  ctx.out(format == "json" and agent_brief.json(brief_opts) or agent_brief.markdown(brief_opts))
  return 0
end

function commands.template(ctx)
  local args, eo = ctx.args, ctx.eo
  local opt = args.opt
  if #args.pos > 0 then
    ctx.warn("error: template takes no positional argument (use --title=...)")
    return 2
  end
  local prio
  if opt.prio then
    prio = model.to_prio(opt.prio)
    if not prio then
      ctx.warn("error: --prio must be 1, 2 or 3")
      return 2
    end
  end
  if opt.lang ~= nil and opt.lang ~= "de" and opt.lang ~= "en" then
    ctx.warn("error: --lang must be de or en")
    return 2
  end
  ctx.out(mutate.template({
    lang = opt.lang --[[@as "de"|"en"|nil]],
    title = opt.title --[[@as string|nil]],
    kind = opt.kind --[[@as string|nil]],
    prio = prio,
    effort = opt.effort --[[@as string|nil]],
    tags = opt.tags and split_commas(opt.tags --[[@as string]]) or nil,
    today = eo.today,
    with_plan = opt["with-plan"] == true,
  }))
  return 0
end

function commands.areas(ctx)
  local format = ctx.args.opt.format or "names"
  if format ~= "names" and format ~= "tsv" and format ~= "json" then
    ctx.warn("error: --format must be names, tsv or json")
    return 2
  end
  if #ctx.args.pos > 0 then
    ctx.warn("error: areas takes no argument")
    return 2
  end
  if format ~= "names" then
    return contract_cli.areas(ctx, format)
  end
  local root, err = vault.root(ctx.eo)
  if not root then
    ctx.warn("error: " .. tostring(err))
    return 1
  end
  for _, a in ipairs(vault.areas(root)) do
    ctx.say(a.name)
  end
  return 0
end

function commands.export(ctx)
  local args, eo = ctx.args, ctx.eo
  local root, rerr = vault.root(eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  local top
  if args.opt.top then
    local n, err = to_int(args.opt.top --[[@as string]], "--top")
    if not n then
      ctx.warn("error: " .. err)
      return 2
    end
    top = n
  end
  local tasks, errors = scan.all({ root = root })
  if not tasks then
    ctx.warn("error: " .. tostring(errors))
    return 1
  end
  local names = {}
  for _, a in ipairs(vault.areas(root)) do
    names[#names + 1] = a.name
  end
  local text = index.render_global(tasks, {
    top = top,
    areas = names,
    links = not args.opt["no-links"],
    link_prefix = args.opt["link-prefix"] --[[@as string|nil]],
  })
  ctx.out(text)
  return 0
end

---The work list of `--from-rules`: a file, or stdin for `-` (one byte over the limit is read, so a larger one is
---refused, not cut).
---@param ctx Tasks.CliCtx
---@param source string
---@return string|nil text
---@return string|nil err
local function read_work_list(ctx, source)
  local rules_import = require("tasks_nvim.rules_import")
  if source == "-" then
    local stdin = ctx.io.stdin or io.stdin
    return stdin:read(rules_import.MAX_BYTES + 1) or "", nil
  end
  local text, err = fsio.read(source)
  if not text then
    return nil, "cannot read the work list: " .. tostring(err)
  end
  return text, nil
end

---`import` and `bootstrap`: the plan of a work list, printed one line per rule; written only with `--apply`.
---@param ctx Tasks.CliCtx
---@param make_area boolean  `bootstrap`: the area is made first
---@return integer
local function import_command(ctx, make_area)
  local rules_import = require("tasks_nvim.rules_import")
  local args, eo = ctx.args, ctx.eo
  local opt = args.opt
  local verb = make_area and "bootstrap" or "import"
  local area = args.pos[1]
  local source = opt["from-rules"]
  if not area or #args.pos > 1 or (not make_area and not source) then
    ctx.warn(
      make_area and "error: usage: bootstrap <area> [--from-rules=<file|->] [--apply]"
        or "error: usage: import <area> --from-rules=<file|-> [--apply]"
    )
    return 2
  end
  if opt.apply and opt["dry-run"] then
    ctx.warn("error: --apply and --dry-run exclude each other")
    return 2
  end
  local lang = opt.lang or "de"
  if lang ~= "de" and lang ~= "en" then
    ctx.warn("error: --lang must be de or en")
    return 2
  end
  local apply = opt.apply == true
  local root, rerr = vault.root(eo)
  if not root then
    ctx.warn("error: " .. tostring(rerr))
    return 1
  end
  -- the work list is read and checked before anything is made
  local doc
  if source then
    local text, terr = read_work_list(ctx, source --[[@as string]])
    if not text then
      ctx.warn("error: " .. terr)
      return 1
    end
    local perr
    doc, perr = rules_import.parse(text)
    if not doc then
      ctx.warn("error: " .. tostring(perr))
      return 1
    end
  end

  if make_area then
    local missing, berr = rules_import.bootstrap_plan(root, area)
    if not missing then
      ctx.warn("error: " .. tostring(berr))
      return 1
    end
    if apply then
      local made, merr = rules_import.bootstrap(root, area)
      if not made then
        ctx.warn("error: " .. tostring(merr))
        return 1
      end
      for _, p in ipairs(made) do
        ctx.say("made\t" .. p)
      end
    else
      for _, p in ipairs(missing) do
        ctx.say("would-make\t" .. p)
      end
    end
  elseif not vault.has_area(root, area) then
    ctx.warn("error: " .. vault.not_an_area_message(area, vault.area_names(root)))
    return 1
  end
  if not doc then
    if not apply then
      ctx.say(("%s\tdry-run\tnothing written; --apply makes it"):format(verb))
    end
    return 0
  end
  local plan, plerr =
    rules_import.plan(doc, area, { root = root, today = eo.today or model.today(), lang = lang })
  if not plan then
    ctx.warn("error: " .. tostring(plerr))
    return 1
  end
  if plan.target ~= area then
    ctx.warn(
      ("note: the work list checked %s, its tasks go to the area %s"):format(plan.target, area)
    )
  end
  local failed = {}
  if apply then
    local res = rules_import.apply(plan, { root = root })
    for _, f in ipairs(res.failed) do
      failed[f.rule_id] = f.err
    end
    if res.index_err then
      ctx.warn("warn: index not updated: " .. res.index_err)
    end
  end
  for _, item in ipairs(plan.items) do
    local a = item.action
    if a == "create" then
      if failed[item.rule_id] then
        ctx.say(("failed\t-\t%s\t%s"):format(item.rule_id, failed[item.rule_id]))
      else
        ctx.say(
          ("%s\t%s\t%s\t%s"):format(
            apply and "created" or "would-create",
            item.id,
            item.rule_id,
            item.title
          )
        )
      end
    elseif a == "exists" then
      ctx.say(("exists\t%s\t%s"):format(item.id, item.rule_id))
    elseif a == "done" then
      ctx.say(("done\t%s\t%s\tfinished, not opened again"):format(item.id, item.rule_id))
    elseif a == "waived" then
      ctx.say(("waived\t-\t%s\t%s"):format(item.rule_id, item.note or ""))
    elseif a == "pass" and item.id then
      ctx.say(
        ("passes\t%s\t%s\tthe rule passes now: the task may be finished"):format(
          item.id,
          item.rule_id
        )
      )
    elseif a == "invalid" then
      ctx.say(("invalid\t-\t%s\t%s"):format(item.rule_id or "-", item.note or ""))
    end
  end
  local c = plan.counts
  local nfailed = vim.tbl_count(failed)
  ctx.say(
    ("%s\t%s\t%d %s, %d exist, %d finished, %d waived, %d pass, %d invalid%s"):format(
      verb,
      apply and "applied" or "dry-run",
      c.create - nfailed,
      apply and "created" or "to create",
      c.exists,
      c.done,
      c.waived,
      c.pass,
      c.invalid,
      nfailed > 0 and (", " .. nfailed .. " failed") or ""
    )
  )
  if not apply and c.create > 0 then
    ctx.say(("%s\tdry-run\tnothing written; --apply creates the tasks"):format(verb))
  end
  return nfailed > 0 and 1 or 0
end

function commands.import(ctx)
  return import_command(ctx, false)
end

function commands.bootstrap(ctx)
  return import_command(ctx, true)
end

---The example task of `init-vault`, by language.
local FIRST_TASK = {
  de = {
    title = "Erste Task: anlegen, bearbeiten, erledigen",
    summary = "Eine Beispiel-Task: ändere sie, setze status=doing und schließe sie mit done ab.",
  },
  en = {
    title = "First task: create, edit, finish",
    summary = "An example task: change it, set status=doing and finish it with done.",
  },
}

---Whether `area` of the vault `root` holds a task (a file or a folder task).
---@param root string
---@param area string
---@return boolean
local function has_tasks(root, area)
  if not fsio.is_dir(root .. "/" .. area .. "/ROADMAP/tasks") then
    return false
  end
  local tasks = require("tasks_nvim.scan").area(area, { root = root })
  return tasks ~= nil and #tasks > 0
end

---Whether `root` is a folder with things in it that do not look like a vault: no `README.md` and no folder with a
---`ROADMAP/` or `Backlog/` in it. A home or project folder must not become a vault by a typo. Hidden entries
---(`.git`, `.obsidian`) do not count: `git init` first and the vault after is the usual order.
---@param root string
---@return boolean
local function is_foreign_folder(root)
  if not fsio.is_dir(root) or fsio.is_file(root .. "/README.md") then
    return false
  end
  local any = false
  for name, kind in vim.fs.dir(root) do
    any = any or name:sub(1, 1) ~= "."
    if kind == "directory" then
      local sub = root .. "/" .. name
      if fsio.is_dir(sub .. "/ROADMAP") or fsio.is_dir(sub .. "/Backlog") then
        return false
      end
    end
  end
  return any
end

---`init-vault <dir>`: a new vault in `dir` with a first area and an example task; nothing overwritten, a dry run
---unless `--apply`. The vault is the positional folder, not `--vault`.
---@param ctx Tasks.CliCtx
---@return integer
commands["init-vault"] = function(ctx)
  local args = ctx.args
  local opt = args.opt
  local dir = args.pos[1]
  if not dir or #args.pos > 1 then
    ctx.warn("error: usage: init-vault <dir> [--area=<name>] [--lang=de|en] [--force] [--apply]")
    return 2
  end
  if opt.vault then
    ctx.warn("warn: init-vault takes the folder as its argument; --vault is ignored")
  end
  if opt.apply and opt["dry-run"] then
    ctx.warn("error: --apply and --dry-run exclude each other")
    return 2
  end
  local lang = opt.lang or "de"
  if lang ~= "de" and lang ~= "en" then
    ctx.warn("error: --lang must be de or en")
    return 2
  end
  -- Checked before anything is made: a bad date would otherwise fail the example task after the vault exists.
  if ctx.eo.today ~= nil and not model.is_date(ctx.eo.today) then
    ctx.warn("error: --today must be YYYY-MM-DD, got '" .. tostring(ctx.eo.today) .. "'")
    return 2
  end
  local area = type(opt.area) == "string" and opt.area or "Inbox"
  local vault_ops = require("tasks_nvim.vault_ops")
  local rules_import = require("tasks_nvim.rules_import")
  local root, terr = vault_ops.check_vault_target(dir, { area })
  if not root then
    ctx.warn("error: " .. tostring(terr))
    return 1
  end
  if is_foreign_folder(root) and not opt.force then
    ctx.warn(
      ("error: %s has files and is no vault (no README.md, no area); --force makes the vault there anyway"):format(
        root
      )
    )
    return 1
  end

  if not opt.apply then
    if not fsio.is_file(root .. "/README.md") then
      ctx.say("would-make\tREADME.md")
    end
    if not fsio.lstat(root .. "/tasks-vault.json") then
      ctx.say("would-make\ttasks-vault.json")
    end
    local missing, berr = rules_import.bootstrap_plan(root, area)
    if not missing then
      ctx.warn("error: " .. tostring(berr))
      return 1
    end
    for _, p in ipairs(missing) do
      ctx.say("would-make\t" .. p)
    end
    if not has_tasks(root, area) then
      ctx.say(("would-make\t%s/ROADMAP/tasks/ (an example task)"):format(area))
    end
    ctx.say(("init-vault\tdry-run\tnothing written to %s; --apply makes it"):format(root))
    return 0
  end

  local res, cerr = vault_ops.create_vault(root, { area }, { lang = lang })
  if not res then
    ctx.warn("error: " .. tostring(cerr))
    return 1
  end
  for _, p in ipairs(res.created) do
    -- folders end in `/`, as `bootstrap` prints them
    ctx.say("made\t" .. p .. (p:match("%.md$") and "" or "/"))
  end
  local made, merr = rules_import.bootstrap(res.root, area)
  if not made then
    ctx.warn("error: " .. tostring(merr))
    return 1
  end
  for _, p in ipairs(made) do
    ctx.say("made\t" .. p)
  end
  if not has_tasks(res.root, area) then
    local first = FIRST_TASK[lang]
    local task, nerr = require("tasks_nvim.mutate").new(area, {
      root = res.root,
      title = first.title,
      summary = first.summary,
      lang = lang,
      today = ctx.eo.today,
    })
    if not task then
      ctx.warn("error: the vault is made, the example task is not: " .. tostring(nerr))
      return 1
    end
    ctx.say(("created\t%s\t%s"):format(task.id, task.path))
  end
  ctx.say(("init-vault\t%s\tuse it with --vault=%s or $TASKS_VAULT"):format(res.root, res.root))
  return 0
end

---The options of every CLI verb (`value`: needs `=value`; `flag`: none), a copy of the table the parser reads. The
---drift spec compares it with the routes of `:Tasks` (`tasks_verbs_drift_spec.lua`).
---@return table<string, Tasks.CliSpec>
function M.specs()
  return vim.deepcopy(SPECS)
end

---Run one command line. `argv[1]` is the subcommand.
---@param argv string[]
---@param io? Tasks.CliIO  defaults to stdout/stderr
---@return integer exit_code
contract_helpers.area_arg = area_arg
contract_helpers.filter_from = filter_from
contract_helpers.to_int = to_int
contract_helpers.cellv = cellv
contract_cli.register(commands, SPECS, contract_helpers)
require("tasks_nvim.cli_learn").register(commands, SPECS)

function M.run(argv, io)
  io = io or M.stdio
  local function say(line)
    io.out(clean(line) .. "\n")
  end
  local function warn(line)
    io.err(clean(line) .. "\n")
  end
  local function out(text)
    io.out(clean(text))
  end

  -- Global options may come before the command (`--vault=x list`): move them behind it.
  local lead = 0
  while
    argv[lead + 1] and (argv[lead + 1]:match("^%-%-vault=") or argv[lead + 1]:match("^%-%-today="))
  do
    lead = lead + 1
  end
  if lead > 0 and argv[lead + 1] then
    -- right behind the command name, NOT at the end: after a bare `--` everything is text (`new area -- --title`), and
    -- an option that landed there would be read as part of the title
    local moved = { argv[lead + 1] }
    for i = 1, lead do
      moved[#moved + 1] = argv[i]
    end
    for i = lead + 2, #argv do
      moved[#moved + 1] = argv[i]
    end
    argv = moved
  end

  if argv[1] == "--capabilities" then
    -- the handshake: `call hello` under a name that needs no method word
    local moved = { "call", "hello" }
    for i = 2, #argv do
      moved[#moved + 1] = argv[i]
    end
    argv = moved
  end

  local name = argv[1]
  if name == nil or name == "help" or name == "--help" or name == "-h" then
    io.out(USAGE)
    return name == nil and 2 or 0
  end
  local spec, handler = SPECS[name], commands[name]
  if not spec or not handler then
    warn("error: unknown command: " .. tostring(name))
    io.err(USAGE)
    return 2
  end

  local rest = {}
  for i = 2, #argv do
    rest[#rest + 1] = argv[i]
  end
  local args, perr = parse_args(rest, spec)
  if not args then
    warn("error: " .. perr)
    return 2
  end
  if args.opt.help then
    io.out(USAGE)
    return 0
  end

  if
    (name == "list" or name == "plan" or name == "estimate")
    and args.pos[1]
    and args.pos[1]:sub(1, 1) == "@"
  then
    local lerr = apply_list(args, args.pos[1]:sub(2), name)
    if lerr then
      warn("error: " .. lerr)
      return 2
    end
  end

  ---@type Tasks.CliCtx
  local ctx =
    { io = io, args = args, say = say, warn = warn, out = out, eo = engine_opts(args.opt) }
  local ok, code = pcall(handler, ctx)
  if not ok then
    warn("error: " .. tostring(code))
    return 1
  end
  -- A handler that forgot its exit code must not read as success (`os.exit(nil)` is 0).
  return type(code) == "number" and code or 1
end

return M
