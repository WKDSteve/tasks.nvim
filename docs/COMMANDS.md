# Editor commands (`:Tasks`)

The commands for the open work of a task vault: one Markdown file per task in `<area>/ROADMAP/tasks/`, a
generated overview `<area>/ROADMAP/TASKS.md`, finished tasks in `<area>/Backlog/`. Format and rules:
[ENGINE.md](ENGINE.md); scenarios: [WORKFLOWS.md](WORKFLOWS.md). All rules live in the engine; this layer only
parses the command line, asks, notifies and opens windows. The same engine runs without an editor as
`nvim --headless -u NONE -l scripts/tasks.lua <command>`.

The grammar is **verb-first** (`:Tasks list my-area`): the composer routes over literal path segments and
has no dynamic first segment. An *area* is a folder of the vault holding `ROADMAP/` or `Backlog/` (plus the
`extra_areas` of `setup()`), which is why areas are read from the vault (argument type `TASK_AREA`). Where a command filters (`list`, `plan`,
`next`, `estimate`, `quickwins`), an *area group* of `<vault>/area-groups.json` (e.g. `nvim` for every `*.nvim`
area) is accepted and completed like an area and stands for its member areas; a write target (`task new`) takes one
area only.
`<Tab>` completes areas, task ids (`<area>/<slug>` of the *open* tasks,
type `TASK_ID`), the filter and `--to=` values and, for `task set`, every settable `key=`.

All mutating commands (`task new`, `task set`, `task done`, `tasks index`) regenerate
the area's `ROADMAP/TASKS.md` through the engine; it is never written by hand (rule
R7). The global overview `ALL/TASKS.md` is **never written** by any command:
`tasks all --to=file:<path>` produces it on demand (decision E2, not committed).

### `:Tasks list [<area>|all] [filters] [--to=] [--format=]`

Lists the open tasks, sorted by status (`doing`, `decision`, `blocked`, `open`,
`parked`), then prio, then area and slug. No area, or `all`, means every area. (The
lowercase word `all` is the keyword; `ALL` with capitals is the area of that name.)

| Flag | Meaning |
|---|---|
| `--status=a,b` | one or more of `doing decision blocked open parked` |
| `--prio=1,2` / `--prio=<=2` | exact prios, or "at most" |
| `--kind=a,b` | `feature task bug idea research` |
| `--category=a,b` | any of `bug security performance docs ruleset ux bindings refactor tests ci learning` (`bug` also finds every `kind: bug`; a tag spelled like a category counts) |
| `--effort=S,M` / `--effort=<=M` | the written effort (`XS S M L XL`, or days like `0.5d`; sizes are case-insensitive), or "this or smaller" (`<=S`, `<=M`, `<=1d`; sizes and days share one scale, a task without effort never matches) |
| `--severity=a,b` | any of `low medium high critical` (the optional `severity` of a bug / security task; a task without one never matches) |
| `--ci=a,b` | the CI state of the task's commits (`ci:`): any of `pending green red`, `none` for a task without one. Mostly with `--done`: `tasks list --done --ci=pending,red` lists the finished tasks whose CI has no verdict yet or is red; `done --ci=pending` writes it with the finish, `set <id> ci=green` the verdict later, on the finished task too ([ENGINE.md](ENGINE.md#the-ci-state-of-the-commits-ci)) |
| `--waits-for=a,b` | the **parked** tasks that wait for one of these keys (`waits_for:`, see [`:Tasks waits`](#tasks-waits-areaall-and-tasks-release-key---dry-run---yes)); `none` finds the parked tasks without a reason. Only a parked task matches, also where a default would hide parked tasks (`quickwins`) |
| `--value=4,5` / `--value=>=4` | the written `value` (1-5, the expected benefit), or "this or more"; a task without a value never matches |
| `--actor=a,b` | any of `cdx me pair none`: who can do it. `me` also finds `status: decision` and the tag `needs-user` (derived, nothing to migrate); `none` finds the tasks nobody classified |
| `--tag=a,b` | any of these tags |
| `--plan=area/slug,...` / `--phase=a,b` | the tasks of these plan files / the tasks in these stages of their plan (the CLI takes the same; `--stale-refs` there is the editor's `--stale=refs`) |
| `--stale=<days>` | not updated for at least that many days (no date counts as stale) |
| `--stale=refs` | a file named in the task's `refs:` changed on a later day than `updated` (git commit date, mtime as fallback); the heading names the changed files. Details in [ENGINE.md](ENGINE.md#--stalerefs----tasks-whose-referenced-files-changed) (section `--stale=refs`) |
| `--blocked` | status `blocked`, or a non-empty `blocked_by` |
| `--reminders` | a reminder (`remind:`) that is due: its date is today or earlier (in Neovim: `:Tasks list --reminders`, and the filter `reminders` in the dashboard's `f` menu; one line at startup says how many are due, off by default, `reminders = { on_start = true }` turns it on). The list shows the open tasks; the finished ones that carry a reminder are named in the startup line (`:Tasks open <id>`) and, headless, listed by `list --done --reminders`. Set with `set <id> remind=+7d` (a date, `+<n>d` or `+<n>w`), taken away with `remind=` (also on a finished task); `done <id> --remind=7d` sets one on the finished task. A named list can hold it (`reminders = true`); `plan` and `estimate` do not take this filter |
| `--overdue`, `--due-before=YYYY-MM-DD`, `--starts-after=YYYY-MM-DD` | the optional `due:` date is before today / before that day; the `start:` date is after that day. A task without the date never matches. `--overdue` is also a flag of `:Tasks list` / `:Tasks tasks`, the filter `overdue` of the dashboard's `f` menu and the saved-list key `overdue = true`; `--due-before` and `--starts-after` are headless `list` only |
| `--ready` / `--waiting` | the tasks that can be started now (nothing open blocks them; a `decision` counts: it waits for you, not for a task) / the tasks that wait on an open blocker. One definition for the plan, the dashboard, `next` and these flags, judged against every open task of the vault (a blocker in another area counts). The two exclude each other |
| `--unestimated` | missing the effort or the value |
| `--quick-win` | a quick win: value and effort at the thresholds of `setup({ quick_wins })` (default value 4+, effort S-). Shorthand for `--value=>=N --effort=<=X`, so it cannot be combined with `--value` or `--effort` (an error, never a silent pick) |
| `--sheet=` | the state of the test-sheet block that `testing sheets report --tasks` (testing.nvim) wrote into the task, by its worst sheet: `red` (failed or does not load), `stale`, `never` (never ran), `inbox` (green, waiting for your judgement), `manual`, `green`, `unknown` (no states line, none of these words in it, or broken block markers; `show` says which); `any` is every task with the block, `none` every task without it (`--tag=needs-live-test --sheet=none`: the live checks that are done by hand; with `--status=open,doing,decision`, or as the list `@abnahme-by-hand`, the third group of the acceptance). A comma list; a task without the block matches only `none`. Nothing is run: it is what the last report wrote. Headless `list` and `:Tasks list --sheet=` (the dashboard opens with only those tasks; its line shows `[sheet: <state>]` and `show` the counts) |
| `--claimed=` | who holds the task now (`claim`): `own` a valid claim of this name (the name `claim` takes without `--by`: `cdx:<session>` in a Claude Code session, else `<user>@<host>`), `foreign` a valid claim of somebody else, `none` free or expired. A comma list. Headless `list`, `:Tasks list --claimed=` and saved lists (`lists save <name> --claimed=foreign`); the dashboard marks a claimed line `[claim: mine]` or `[claim: <who>]` either way and shows the filter as the chip `[claimed: ...]` |
| `--sort=default` / `prio-effort` / `severity` / `frecency` / `roi` / `due` / `created-desc` / `created-asc` / `updated-desc` / `updated-asc` / `remind` / `title` (`due`: earliest `due:` first, tasks without one last; the dates: a task without the date last in both directions, a tie in the default order; `title`: alphabetical regardless of case; not with `--done`; the dashboard's `o` cycle stops after `due`, a saved list can use any of them) | the order (`roi`: highest `value / effort` first, tasks without both numbers after the ones with a figure, each group in the default order): `default` is status, prio, area, slug; `prio-effort` is status, prio, then effort ascending (important and small first, no effort last of its prio); `severity` is `critical` first, then `high`, `medium`, `low`, no severity last, each group in the default order; `frecency` is what the dashboard opened or changed most first (see below), the rest in the default order |
| `--to=` | where the list goes: `buffer` (default), `clipboard`, `qf`, `file:<path>`, `echo`, `mdview` (Markdown written to a temp file and shown in the browser by [mdview.nvim](https://github.com/WKDSteve/mdview.nvim); see [Browser preview](#browser-preview-mdview)) |
| `--format=md` / `--format=csv` | table (default) or CSV with the extra columns tags, blocked by, summary, path, severity, value, roi, actor, waits for; a `file:` target ending in `.csv` implies `csv`. A CSV cell that starts with `=`, `+`, `-`, `@` or a tab gets a leading `'`, so a title like `=HYPERLINK(...)` is text, not a formula, when the file is opened in a spreadsheet |

```vim
:Tasks list                                    " everything open, in a scratch buffer
:Tasks list lib.nvim --status=doing,decision
:Tasks list --status=decision --to=qf          " what is waiting for me, jump into the files
:Tasks list --stale=60 --to=clipboard
:Tasks list --status=open --effort=<=M --sort=prio-effort   " important and small first
:Tasks list --category=bug,security --sort=severity         " worst first
:Tasks list all --to=file:~/vault/ALL-TASKS.md
```

The command line splits at spaces, so a `--to=file:` path with a space needs a backslash before
each space (`--to=file:C:/my\ dir/tasks.csv`). A word a command has no use for is an error
(`unexpected argument: ...`), not silently ignored -- otherwise the export would go to a file named
after the part before the space.

The scratch buffer is plain Markdown (yank it, `:sort` it, search it) with a heading and
the active filter above the table. `qf` puts one entry per task into the quickfix list,
each jumping to the task file. Rendering and delivery are `lib.nvim.harvest` (`render`,
`emit`) and `lib.nvim.ui.list`. Nothing is delivered when no task matches; the command
says so instead.

### The dashboard (`:Tasks list [<area>|all]` without `--to=` / `--format=`)

An interactive `Snacks.picker` (source `tasks_nvim`):
one line per open task -- prio, status, effort, area, title, the `[severity]` of a bug /
security task and a `<- blocker` hint -- the task file as the preview, and a title with the
counts, the active filter chips and, when it is not the default, the sort order:

```
 Tasks (lib.nvim) · 41 open · 3 decision · 5 blocked  [status: open,doing] [prio: <=2] [sort: prio-effort]
```

| Key | Action |
|---|---|
| `<CR>` | open the file (all marked ones when there are marks) |
| `<Tab>` / `<S-Tab>` | mark / unmark (snacks' own multi-select; the marks are the target of `s p D e`) |
| `s` | advance the status of the marked (else the current) tasks: `doing` -> `decision` -> `blocked` -> `open` -> `parked` -> `doing` |
| `p` | advance the prio: none -> 1 -> 2 -> 3 -> none (3 -> none removes the key) |
| `D` | finish after **one** confirmation naming every task (engine `done`, moved to `Backlog/`) |
| `f` | set a filter chip: pick `status`, `prio`, `effort` (`XS`..`XL`, `<=S`, `<=M`), `kind`, `category`, `severity`, `value`, `actor`, `tag`, `blocked`, `reminders` (toggle: shown as the chip `[reminder due]`), `overdue` (toggle: the chip `[overdue]`, the `due:` date is before today), `unestimated`, `quick-win` (toggle: value and effort at the quick-win thresholds, shown as the one chip `[quick-win]`), `stale-refs` (toggle: shows the chip `[stale: refs]`),
`plan` and `phase` (the plans and stages in use), `readiness` (`ready` / `waiting`: the same cut as `list --ready` / `--waiting`, which the dashboard keeps when it was
opened with them) or "clear all", then a value (`(any)` clears one chip) |
| `gl` (input window `<M-l>`) | named lists, each with the number of open tasks it selects (`abnahme-by-hand (26)`; a list that checks refs is not counted): pick one to make it the view (its filter, sort and area), `Save the current filter and sort as a list ...` (asks for a name; replacing a saved list asks first), `Rename a saved list ...`, `Delete a saved list ...`. Lists of `setup()` and built-in lists cannot be deleted here |
| `o` | cycle the sort order: `default` -> `prio-effort` (small first within a prio) -> `severity` (critical first) -> `frecency` (most opened / changed first) -> `default`; a non-default order shows as `[sort: ...]` in the title |
| `e` | export the marked (else all shown) tasks: scratch buffer, clipboard, quickfix or a file, as Markdown or CSV, or "Preview in browser (mdview)" -- the `--to=` sinks |
| `v` | switch to the **stage view**: tasks grouped by stage ("Stage 1 · 5 tasks · not parallel"), what each waits for, tasks without plan, edge or dependants in an "Unsorted" block; `v` again returns to the list (marks and filter stay) |
| `P` | give the marked (else current) tasks a plan (an open plan file) and one of its stages: `plan:` / `phase:` in one batch |
| `J` / `K` | stage view: move the task down / up among its stage's tasks: `order` becomes a fraction between the two neighbours, nothing is renumbered. `order` only breaks ties behind status and prio, so the move shows among tasks of equal status and prio |
| `r` | rescan the vault now (the list also refreshes by itself, see "Live refresh"); keeps the cursor task and the marks |
| `gp` | preview the task file under the cursor in the browser through mdview.nvim ([Browser preview](#browser-preview-mdview)); the single-task menu of the plain fallback has "preview the file (mdview)" |
| `ga` | attach a screenshot to the task under the cursor: the clipboard image, else the newest screenshot (`attach.screenshot_dirs`, `attach.max_age_s`), the same as `:Tasks attach <id> from=clipboard\|latest`; the task becomes a folder task and the link is copied to the `+` register (nothing available: one message, nothing attached). The single-task menu of the plain fallback has "attach a screenshot" |
| `gb` / `gr` | the Backlog picker (`:Tasks folder <area> backlog`) / `ROADMAP/ROADMAP.md` of the area under the cursor |
| `gh` / `gH` | hand the task under the cursor to an agent, the same as `:Tasks agent <id> mode=prefill` / `mode=run` (see `:Tasks agent` below): ai-desktop's job intake, else ai.nvim; it says what happened and asks where `:Tasks agent` asks. Only while the AI functions are on (`setup({ ai = ... })`): otherwise neither key nor help line nor menu entry. The single-task menu of the plain fallback has "hand to an agent (prefill)" and "hand to an agent and run it" |
| `g?` | key help float (any key closes it) |

The letters work in the list window. In the input window they would shadow the editing
commands (`s`, `p`, `D`, `e` in normal mode) and the typing in insert mode, so there the same
actions are Alt chords (normal and insert mode): `<M-s>` `<M-p>` `<M-d>` `<M-f>` `<M-o>` `<M-e>`
`<M-r>`, `<M-i>` (attach a screenshot), `<M-b>` (backlog), `<M-m>` (roadmap), `<M-v>` (preview), `<M-h>` / `<M-H>` (agent), `<M-?>` (help). `s` and `p` are applied
at once, as **one batch**: every task advances from its own value, one `tasks.mutate.set`
per task without its own index write, then each touched area's `ROADMAP/TASKS.md` is
regenerated **once**, and one notification reports `changed / unchanged / failed`. The
picker stays open and rescans. `D`, `f`, `e`, `gb`, `gr`, `gp`, `gh` and `gH` ask something or open a window, and snacks
closes a picker whose window loses focus, so they close it first; `D` and `f` reopen it
afterwards (the marks are gone then), `e` does not when it delivered something.

The last filter and sort order are remembered between sessions (`lib.nvim.store.project`,
keyed by the vault, key `tasks/dashboard-filter`). A filter given on the command line
(`--status=...`) wins for that session and is not stored until it is changed with `f`; the
same goes for `--sort=` (the default order is "not given": the remembered one applies, `o`
cycles back to it). An empty result
stays open (`show_empty`), so a filter that matches nothing can be cleared with `f`.

**Backends.** `setup({ dashboard = { backend = ... } })`: `snacks` (snacks.nvim; letter keys in the list window),
`kit` (lib.nvim's own picker, **no snacks needed**: marks with `<Tab>`, highlighted rows, a file preview, the same
live refresh, the stage view, `P` and `J`/`K`; the prompt keeps the focus, so the keys are the Alt chords of
`keys.dashboard_input`, e.g. `<M-s>`, `<M-g>`, `<M-a>`), `select` (below) or `auto` (default): snacks when installed,
else kit.

Without a picker (`backend = "select"`) a `vim.ui.select` flow lists the same tasks; picking one opens a menu
(open the file, advance status / prio, finish, filter, next sort order, export the list,
Backlog, ROADMAP.md) for **that one task** -- no marks, no batch. It never raises.

**Live refresh.** While the dashboard is open it watches the folders its list is made of
(`ui/dash_watch.lua`, handles from `lib.nvim.fs.watch`): `<area>/ROADMAP/tasks` and each
folder-task folder in it, and `<area>/Backlog/FEATURES` and `Backlog/TASKS` where finished
tasks land -- the shown area, or every area for `all`. When a file changes (this Neovim,
another one, a Claude session, `git pull`) the list rescans by itself, after 250 ms of quiet
(a burst of events is one rescan). Cursor and marks are found again **by task id**, so they
stay on the same tasks even when a rescan moved rows around; filter chips and the sort order
are not touched. A rescan that finds the same list (files in the folder that are no tasks, a
file saved unchanged) redraws nothing. The dashboard's own batches (`s`, `p`) are not echoed:
their file events are muted and no second scan runs. Closing the picker (any way out,
including the `D` / `f` / `e` detours) stops every handle and timer; the reopened dashboard
starts its own. Only direct folders are watched (libuv's `recursive` flag does nothing on
Linux), so after every refresh (and after `r`) the handles are re-aimed: a folder task
created while open is watched from then on. An area that has no `ROADMAP/tasks/` yet is
watched at `ROADMAP/` until the folder appears (its first task is noticed, however the burst of
events ends: `lib.nvim.fs.watch` reports only the last file name of a burst). A whole new area is only noticed by `r` or by
reopening the dashboard (the vault root itself is not watched). Off with `setup({ dashboard = { watch = false } })` (or per call `open(v, { watch = false })`); the debounce
is `dashboard.debounce_ms` (default 250). If no
folder can be watched (handle limit, no `lib.nvim.fs.watch`) the dashboard says so once and
`r` stays the way to rescan. The plain `vim.ui.select` fallback has no live list.

**Frecency.** Opening a task (`<CR>`, or "open the file" in the fallback menu) or changing it
(`s` / `p`) counts as a visit: `tasks_nvim.frecency` keeps a decayed counter per task id --
each visit adds 1, the old count halves every 14 days (a task opened three times today
outranks one opened five times last month, one left alone fades out after a couple of
months). The file is `stdpath("state")/tasks/frecency.json` (`$TASKS_FRECENCY_FILE`
overrides it; at most 500 entries, the lowest scores go first; a corrupt file starts empty and
is kept as `frecency.json.bad`). `o` -> `frecency` (or `:Tasks list --sort=frecency`,
`tasks list --sort=frecency` in the CLI) lists the tasks with a score first, highest first,
and the rest in the default order. It is opt-in because it ignores the status/prio order the
default list is for: a `parked` task you keep opening is above an untouched `doing` one.

*Seam.* `require("tasks_nvim.ui.cmd").dashboard` decides what
happens: `nil` (the default) opens this dashboard, a function replaces it
(`view = { tasks, area, filter, sort, root }`), `false` gives the scratch buffer back.

### `:Tasks index [<area>] [--all] [--check]`

Without `--check`: (re)writes `ROADMAP/TASKS.md` of the area (all areas without an
argument or with `--all`), only where the content changed, and removes a stale one when
no task is open any more. With `--check`: writes nothing and runs the rule check of the
engine -- missing or invalid frontmatter, unknown status/kind/prio/effort, dangling
`blocked_by`, a `[[slug]]` wikilink that names no task (`wikilink-dangling`) or one in several areas
(`wikilink-ambiguous`, with the candidates), a stale or missing `TASKS.md`, a `done` task in `ROADMAP/`, an open one in
`Backlog/`, ... -- and reports the findings (a notification, or a scratch buffer when
there are more than ten). Errors are `ERROR` level, warnings `WARN`.

### `:Tasks new` -- the form (no arguments)

`:Tasks new` without an area opens a Markdown form in a split, as a Markdown
template:

```markdown
# New task
Area: lib.nvim
Title: Notify: unify the output channels

## kind (one)
- [ ] feature
- [x] task
...
## category (several)
- [ ] bug
- [x] docs
...
## scope (several)
- [x] ui
...
Other: keymap, newword
## scaffold (several)
- [x] Mapping only through the config, no default
...
Tags: ui, notify
Refs: lua/foo/init.lua
```

The choice fields `kind`, `prio`, `effort`, `value`, `actor`, `category`, `scope`, `severity` and `status` are bullet
lists whose values come from the engine (`tasks.model`); `category` and `scope` take several ticks, the
others one (ticking a bullet clears its siblings; leaving a list empty means "not set", and
`kind` / `status` then get the engine defaults `task` / `open`). `Area:` and `Title:` are
required; the `## scaffold` block lists acceptance lines for the kind, categories and scopes ticked above (a bug: reproduction, regression test, version; a feature with `bindings`: usercmd, keymap, config, docs and tests; `ruleset`, `security`, `api`, `multi-repo` and more, from `tasks.model`). They are ticked in advance and follow every tick above; untick one to drop it, the ticked ones become `- [ ]` lines at the top of `## Akzeptanz`. `severity` fits `bug` and `security` only (its heading says so; elsewhere it is told on submit, never refused); `Other:` (under `scope`) takes words: a scope word joins the ticks, any other word goes to the tags and the form says so; `Tags:`, `Refs:` and `Links:` are comma separated (`Links:` takes web addresses, `http://` or `https://`;
anything else is reported; `Refs:` takes paths and commits; `:Tasks new links=https://...` pre-fills it). `After:` (task ids, comma separated), `Plan:` (a plan id), `Project:` (the project of a task that belongs to the project itself, instead of a plan), `Phase:` (a stage of that plan), `Due:` and `Start:` (`YYYY-MM-DD`, start never after due) are plain lines too; an id that exists nowhere, a plan that is none or a phase the plan does not name is refused by the engine when the form is submitted (the same words as `set`), a date that is none by the form itself; `:Tasks new after=... plan=... project=... phase=... due=... start=...` pre-fills them. `Area:` may name several areas (`lib.nvim, cascade.nvim`): one
task with the same text is created in each (every area is checked first; a bad one creates nothing). `Summary:` is the
one line that ends up in the index. The sections `## Kontext`, `## Akzeptanz` and `## Notizen` at the end are free
text and become the body of the task (an `Akzeptanz` line without a checkbox becomes `- [ ] line`; a section left
empty keeps the template's hint comment). `key=value` words on the command line
(`:Tasks new kind=bug category=docs,ruleset tags=a`) pre-tick the form. A hint line
lists the areas of the vault.

The form opens as a centered float. `:Tasks new mode=float|split|vsplit|current` (or
`setup({ form = { mode = "split" } })`) picks the window: a float, a split below, a vertical split or the current
window.

| Key (form buffer) | Does |
|---|---|
| `<Space>` / `<CR>` on a bullet | tick / untick it (`<CR>` on other lines is a plain `<CR>`) |
| `<C-s>` (normal and insert) | submit |
| `q` (normal) / `<C-q>` | cancel -- nothing is created |
| `g?` | help in a float that stays until `q` / `<Esc>` or until you leave it |
| `<C-e>` (normal) | pick the icon with emojis.nvim (soft dependency) into the `Icon:` line |
| `g?` | help |

The tick is cascade.nvim's checkbox toggle (`require("cascade").toggle_checkbox`) when that
plugin is installed (a soft dependency, wrapped in `pcall`), with the result normalised to
the form's rules; without it, or when cascade does nothing on that line, the form flips the
bullet itself on the same keys.

Submitting checks the form: the problems are written at the top of the buffer as `!` lines
(they vanish on the next submit), and nothing is lost -- the buffer stays as it is. A valid
form asks **"Attach assets?"**: *Yes* creates a folder task (`<slug>/<slug>.md`, as
`--folder` does), makes `assets/` and opens the file explorer on it (filetree.nvim's
`:Filetree open` when installed, else Neovim's directory browser); *Yes, attach a screenshot* creates the
folder task too and attaches the clipboard image to it, else the newest screenshot (as
`:Tasks attach <id> from=clipboard|latest`; the link goes into the new task, which opens); without an image
anywhere the task is still made and one message says that nothing was attached; *No* creates a plain task
file; `<Esc>` / `q` creates nothing and leaves the form open with everything typed. The task is written by `tasks.mutate.new`, the one write path the CLI uses as well; an
error of the engine (a tag with a forbidden character, say) is shown in the form, which stays
open. Afterwards the form closes and the new file opens.

With an area (`task new <area> ...`) nothing changes: that is the old behaviour below.

Seams for tests and other front ends: `ui.cmd.form_open` (replaces the form buffer,
signature of `ui.form.open`) and `ui.cmd.explorer_open(dir)`.

### `:Tasks new --draft <text...>` -- the form, filled in from a free text

`:Tasks new --draft Der Knopf im Formular soll blau sein` (or `:'<,'>Tasks new --draft`
over a note, a piece of a mail; typed words and the selection together are the text)
asks for the fields of the new task and opens the form above with them filled in:
title, area, kind, prio, effort, value, tags, category, plan, summary and the
acceptance lines. Nothing is created: `<C-s>` creates the task as always, every field
stays as editable as a typed one, and `q` drops it. Only while the AI functions are on
(`setup({ ai = ... })`).

- With a running ai-desktop, the text goes to its job of the kind `draft-task`
  (`POST /jobs`, docs/JOBS.md "Drafts" of ai-desktop) with the values this vault allows
  (`choices`: its areas, the kinds and categories, the tags of its open tasks, the ids of
  its plans). The dashboard does not come to the front; the editor watches the job.
- The area is not chosen yet, so the text counts as private (the strictest class): a
  local model of ai-desktop answers at once; when its jobs model does not run on this
  machine, ai-desktop holds the job and the editor asks first ("Send the text there
  anyway?"); only a yes runs it (`POST /jobs/<id>/run` with `confirm_private` and the
  control secret). No sends nothing and puts the waiting job away (`DELETE /jobs/<id>`
  with the control secret), so that it does not stay in the dashboard; when that fails
  (ai-desktop ended meanwhile) the message says that the job still waits there.
- Without ai-desktop, ai.nvim answers once with the same prompt, after a question
  (ai.nvim may send it to a model outside this machine).
- The answer is checked again here (`tasks_nvim.draft.check`, the rules of ai-desktop's
  `draft::check`): a value this vault does not know is left out and named in a message;
  a wrong shape or a control character fills in nothing and says why.

### `:Tasks new <area> [title...] [kind= prio= effort= tags= status=]`

Besides these keys `value=`, `actor=`, `after=`, `order=`, `plan=`, `phase=` and `waits_for=` are accepted
(`waits_for=mac` creates the task parked, waiting for that key; the form does not offer it).

Creates `<area>/ROADMAP/tasks/<slug>.md` (slug from the title; a taken slug gets `-2`,
`-3`; a slug used in `Backlog/` counts as taken), regenerates the index and opens the
file. The words after the area are the title; one surrounding pair of `"` is dropped.

```vim
:Tasks new lib.nvim Notify: unify the output channels kind=feature prio=2 tags=ui
:Tasks new cascade.nvim "Cycle: count support" effort=S
:Tasks new lib.nvim                         " asks: title, kind, prio, effort
```

Without a title it asks for it -- through `ui.kit.form` (ui.nvim) when installed, else a
chain of `vim.ui.input` prompts. Fields already given as `key=value` are not asked again;
`<Esc>` on an optional field leaves it out, `<Esc>` on the title cancels. Tags may not
contain `, [ ] " ' #` (they sit in an inline list).

**With a range** (a visual selection, or `:5,10Tasks new <area>`) the task is *about those lines*: it gets a
`refs:` entry for them (`lua/a.lua:5`: file relative to the working directory, first line -- the staleness check
reads it) and, when you typed no title, the first non-blank selected line as the title. Without an area the form
opens with the same title and ref filled in.

```vim
:'<,'>Tasks new lib.nvim                    " title = first selected line, refs = this file:line
```

On the command line `tasks new <area> <title> --created=YYYY-MM-DD` puts a task on the record on an earlier day, never a later one (history written
down later; `updated` stays today). A title that starts with `--` goes in as `--title=--diagnose ...` (or after a `--`
that ends the options).

`tasks new` writes the file as asked even when the `plan`, `project` or `phase` it names exists nowhere yet (a plan may follow), and says
so on stderr as `warn: <id>: plan X is no plan file ...`; `tasks check` reports it later as `plan-unknown` and the like.

### `:Tasks set <id> key=value ...`

Changes frontmatter of an *open* task and sets `updated` -- but only when something really
changed (an identical value rewrites nothing). Settable: `title status waits_for kind prio effort tags
category scope severity value actor summary blocked_by after order plan phase refs rules done_in commits created remind due start repeat repeat_from repeat_after repeat_step`. A value may contain spaces
(`title=Fix the thing status=doing`: a word that does not start with a known `key=`
continues the value before it); an empty value removes the key (`kind=`). `status=done` is
refused: finishing moves the file, see `task done`. A *finished* task takes `remind=` only (a date, or `+7d` / `+2w` from today;
an empty value takes the reminder away) and nothing else: the startup line names the finished tasks whose reminder is due, so
there is a way to clear it. A buffer showing the file is reloaded when it has no unsaved changes.

`waits_for=<key>` says **why a task is parked**: something outside is missing (a machine, a licence, somebody else's
decision). The key is one word of your own (lower-case letters, digits and `-`, at most 40 characters; `none` is
reserved). It belongs to `status: parked`, and the engine keeps the two together in one write: `waits_for=mac` on a task
that is not parked parks it, and any status other than `parked` (`set`, the dashboard's `s`, a batch, `done`, a reopen)
drops the key. `status=open waits_for=mac` in one command contradicts itself and is refused; `waits_for=` alone removes
the reason and leaves the task parked by choice.

```vim
:Tasks set lib.nvim/port-the-installer waits_for=mac     " parked, and it says why
:Tasks set lib.nvim/port-the-installer status=open       " back in play; the reason is gone
```

`blocked_by`, `after` and `plan` take ids and Obsidian wikilinks alike (`blocked_by=lib.nvim/a,[[b]]`,
`plan=[[lib.nvim/big|Big]]`): `[[<area>/<slug>]]`, with an alias or a heading, the vault path of the file
(`[[<area>/ROADMAP/tasks/<slug>]]`), and a bare `[[<slug>]]` when exactly one task or plan of the vault has that slug
(several: refused with the candidates, `wikilink-ambiguous`; none: `wikilink-dangling`). A comma inside `[[...]]` does
not split. What is written: an id the file already names keeps its form, a value you give as a wikilink is written as
you gave it, and any other id in the form `setup({ links })` asks for -- `plain` (the default) writes `lib.nvim/a`,
`wikilink` writes `"[[a]]"` when the slug is unique in the vault (to a finished task its file name,
`"[[2026-09-01_a]]"`, which Obsidian finds in `Backlog/`) and `"[[lib.nvim/ROADMAP/tasks/a|lib.nvim/a]]"` (the
path, which Obsidian resolves, with the id as alias) when it is not. The same rule holds for `:Tasks new` (`after=`,
`plan=`), the dashboard's assign (`P`), a move to another area (a bare `[[slug]]` still fits and is kept, an
`[[old-area/slug]]` is rewritten) and `done --unblock` (it only sets the status: no reference is rewritten). The
headless CLI has no `setup`: `TASKS_LINKS=wikilink` switches it there. Neovim reads it too as long as `setup()` names
no `links`; a `links` given to `setup()` (also `"plain"`) wins.

**Headless, a learning path, plan or project:** `tasks set <id> key=value ...` with the id of an open learning path,
plan or project file (and no open task of that id) changes the frontmatter of that file, the same as `path_set`,
`plan_set` and `project_set` of the write door (`plans.SET_KEYS`): a path takes `title`, `status` (`planning`,
`doing`, `parked`; finished with `path_close`), `areas`, `target`, `project`, `links`, `icon`, `cover` and `tags`; a
plan also `phase_order`, `gate`, `phase`; a project `phase_order` and `gate`. Lists are written with commas
(`areas=a,b`, `tags=not-on-workstation`), an empty value removes a key (not `title`, `status`). A change that would
leave the file wrong (a project that is none, an unknown status) is refused (exit 2) and nothing is written.

```sh
tasks set tasks-desktop/rust-stack-a-rust-kern project=tasks-desktop/rust-stack-der-app-familie status=doing
```

A new task whose slug another area already has turns every bare `[[slug]]` that named the old task into a
`wikilink-ambiguous` one. `new` (CLI, `:Tasks new` and its form) says so at once and names those tasks:
`warn: [[dep-a]] now names cascade.nvim/dep-a and lib.nvim/dep-a: wikilink-ambiguous in lib.nvim/linked (write the id
there)`. The task is created all the same.

### `:Tasks task answer <id> [question=<q1|#n> option=<n|clear>]`

Answers a question of the `## Offene Fragen` section of an open task ([the format](CONTRACT.md#the-questions-of-a-task)). With `question=` and `option=` the answer is written
(`option=clear` takes it back). Without them the open questions are asked one after the other, with the options as a choice list; the recommended option is
marked `(recommended)`. The status and the actor of the task stay as they are. Command line: `answer <id> <q1|#n> <n|clear>`.

### `:Tasks sheet-run [<id>] [--dry-run]`

Runs the test sheets of a live-check task now, without starting a suite: testing.nvim's
`testing sheets run --task <id> --tasks <vault>` finds the sheets that name the task (in the area's repository), runs
them headless and writes their state into the task's block, the one `show`, the dashboard and `list --sheet=` read
(a red sheet: its first failure line). Without an id: the task of the current buffer (its file, or any file in a folder
task's folder). The result comes back as one notification with its reason (green; red; the task was not written;
refused; testing.nvim failed or was stopped); an open buffer of the task is reloaded. `--dry-run` runs the sheets but
only says how the block would change. A run is stopped after 30 minutes. testing.nvim writes the block through this
plugin's own engine (`--tasks-cli` is handed on), never through another checkout it might find.

Whether a sheet may run is testing.nvim's decision: the workspace trust of the repository, and on the workstation
(`NVIM_MACHINE_ROLE=workstation`) only with `TESTING_ALLOW_WORKSTATION=1`. testing.nvim is found by
`setup({ sheet_run = { testing_cli = <path to scripts/testing.lua> } })`, `$TESTING_NVIM_DIR`, `$REPOS_DIR/testing.nvim`,
`<vault>/../testing.nvim` or `stdpath('data')/lazy/testing.nvim`. Command line: `sheet-run <id> [--testing-cli=<path>]
[--dry-run]`, with the exit code of `testing sheets run` (0 green, 1 red or not written, 2 refused or no sheet, 3
testing.nvim or the engine not reached).

### `:Tasks sheet-ai draft|explain|ask|accept|bug [<id>]`

The AI link for a live-check task. Without `ask` no model is called. ai.nvim's headless entry, and with it the way
from the app, comes later:

* `ask` (in a hand-over buffer, needs ai.nvim) sends the document above the marker to ai.nvim after you confirm, and
  puts the answer below the marker, replacing what is there. Exactly the document leaves the machine: no buffer,
  selection or diagnostics of ai.nvim's context. Nothing is written but the buffer: `accept` and `bug` still ask.

* `draft` puts a hand-over document into a scratch buffer of its own (`tasks://sheet-ai/draft/<id>`) and onto the
  clipboard: the task, the rules of the sheet format and the skeleton (testing.nvim's `testing sheets prompt draft`).
  Paste it into the AI of your choice and its answer below the marker line of the buffer.
* `accept` (in that buffer) shows the whole sheet of the answer (its last ```lua block, any case) and, after you
  confirm, hands exactly that to `testing sheets accept`, which writes `TESTS/sheets/<id>.sheet.lua` only when it
  loads, names the task and no such sheet exists. A second `draft` of the same task reuses its buffer; the buffer is
  hidden, not wiped, when its window goes, so a pasted answer is not lost.
* `explain` runs the task's sheets (as `sheet-run` does, writing nothing) and puts the red ones into a hand-over:
  failure lines, snapshot files, the sheet's source (`testing sheets prompt explain`).
* `bug` (in that buffer) reads the answer's ```task block (`title:`, `summary:`) and, after you confirm, creates a
  `kind: bug` task in the live check's area that names the live check.

Without an id: the task of the hand-over buffer, else of the current buffer. What the model sees is exactly the
document (testing.nvim docs/SHEETS.md, "Hand over to an AI"); a vault or repository whose path names `tricentis` is
refused. Command line: `sheet-ai draft|explain <id>` prints the document; `sheet-ai accept|bug <id> --from=<answer
file>` shows the sheet or the bug task and writes it only with `--yes`.

### `:Tasks agent [<id>] [mode=prefill|run] [kind=handoff|review-done|draft-task|prepare-decision|split-plan]`

Hands the task (the named one; without an id the task of the current buffer) to an agent, the way the button of
tasks-desktop does. The command is there while the AI functions are on (`setup({ ai = false | true | "auto" })`,
`tasks_nvim.ai`): out of `<Tab>` and refused while they are off.

**To ai-desktop**, when it runs on this machine (`tasks_nvim.agent`):

1. Its `hub.json` (in `$AI_DESKTOP_CONFIG_DIR`, else `%APPDATA%\ai-desktop`, `~/Library/Application Support/ai-desktop`,
   `$XDG_CONFIG_HOME/ai-desktop` or `~/.config/ai-desktop`) names port, pid and instance; it counts only while that
   process lives and, on Windows, did not start more than 2 s after the file was written (a younger one got the id of
   an ended ai-desktop; the rule of `appkit_core::family`). Only files are read for the question whether ai-desktop is
   there, and on Windows the start of that one process.
2. `GET /health` on `127.0.0.1:<port>` must answer as ai-desktop with the instance of `hub.json`: another program that
   took the port gets no secret.
3. `control.secret` beside `hub.json` (64 hex digits, new with every start of ai-desktop) is read for this call and
   sent only in the `Authorization: Bearer` header. It is never shown, logged or put on a command line: the request
   goes over `vim.uv` TCP, not through curl.
4. On Windows `AllowSetForegroundWindow(<pid>)` (LuaJIT FFI) gives ai-desktop the right to bring its dashboard to the
   front. Windows grants it only to the process with the last input; a Neovim in a terminal usually is not that one,
   then the task bar button of the browser flashes instead.
5. `POST /jobs` with `{ source: "tasks.nvim", task_id, title, markdown, vault, area, mode, kind }`; the answer names the
   job (`prefilled`: it waits in the dashboard, `running`, `needs_confirmation`: a private area that ai-desktop asks
   about first). The vault has no class of its areas, so none is sent: ai-desktop's own `private_areas` decide.

Every later request with the secret about that job (`POST /jobs/<id>/run` after a yes here, `DELETE /jobs/<id>` after a
no) goes to the port of the hand-over and asks `GET /health` again first: only the same instance gets the secret. A
question here may stay open for long; when ai-desktop restarted meanwhile (another port, another secret) and another
program took the old port, that program gets nothing and the message says so. Before a `DELETE` the editor asks where
the job is (`GET /jobs/<id>`): a job that was confirmed in ai-desktop's dashboard meanwhile runs or has run, it is left
as it is (a `DELETE` would cancel it) and the message says that the text went to the model from there.

`mode=prefill` (the default) leaves a new job that waits; `mode=run` starts it at once (Claude Code with the brief
of `agent-brief` unless ai-desktop is set otherwise). `kind` names what the job asks for (default `handoff`). A refusal
of ai-desktop is said with its message (`ai-desktop refused the task (403): jobs from other apps are turned off ...`).

**A review** (`kind=review-done`) checks a finished task against its acceptance: the id may name a task in
`Backlog/` (and only a review takes one), `mode` is `run` unless said. ai-desktop reads the diffs of the task's
`commits` itself and lets its agent only read (ai-desktop `docs/JOBS.md`, "Reviews"). The editor watches the job
(`GET /jobs/<id>`, every 3 s, at most an hour) and, when it is done, shows the review block of the answer in
`tasks://review/<id>`: `## Prüfung`, one line per criterion (met, open, not checkable, with evidence). Only after a yes
is it written into the task file as that section (a review of the same heading replaces the last one; `updated`
changes), through the engine's operation `set_section`, which also takes a finished file in `Backlog/`. When the review proposes a follow-up
task (`### Folgetask (Vorschlag)` with `- title:` and `- summary:`), a second question creates it in the same area.
Without a block, or when the job failed, a message says so and nothing is written. A review needs ai-desktop: ai.nvim
does not stand in, since it cannot read the commits. While the AI functions are on, `:Tasks done` ends with the line
`check it against its acceptance: :Tasks agent <id> kind=review-done` (a hint; nothing runs).

**A prepared decision** (`kind=prepare-decision`) is for a task that waits for the person (`status: decision`; any
other status is refused). ai-desktop's agent reads the task, the commits and files its `refs` name and the
repository of the area, and decides nothing. Its answer comes back as for a review, in `tasks://decision/<id>`: a
section `## Vorschlag` (2 to 4 options with consequences, the recommendation with its reason, open assumptions) and
`## Offene Fragen` in the format of the questions (`### ...? [q1]`, unticked options, one `(empfohlen)`). Both go into
the task only after a yes, through the engine (`set_section`): the proposal replaces an earlier one, the
questions go in only when the task has none of its own (those are the person's and stay). The status stays
`decision`; the person answers with `:Tasks answer <id> q1 <n>` (or in the question view of tasks-desktop).

Why both: the proposal keeps the reasons where the task is read, and the questions make the choice one answer that
the engine already knows how to write, instead of a second format.

**A split of a plan** (`kind=split-plan`) takes a plan id (`<area>/<slug>` of `ROADMAP/plans/`, also completed; without
an id the plan of the current buffer); another kind refuses a plan. The plan file goes to ai-desktop with the list of
its tasks, open and finished (id, status, phase, title), so that the drafts do not repeat them; ai-desktop's agent only
reads and answers with drafts (title, area, kind, prio, effort, value, phase, summary, acceptance, `after`,
`blocked_by`; `#N` names another draft). They come back as a list in `tasks://split/<plan>`: tick the ones to create
(`[x]`), then `:w`. After a yes the engine creates them in order (`mutate.new` with `plan`, `phase`, the summary and a
body with the acceptance; `#N` becomes the id draft N got; `blocked_by` is set afterwards). A phase the plan does not
have is asked for on its own and then added to its `phase_order`; without that yes the drafts of that phase are
refused. A draft whose value the engine refuses (a kind that is none, an unknown area) is refused alone, with the
reason, and the buffer marks each ticked line `[+] ... -> <id>` or `[!]`. Nothing is created without the tick, the
`:w` and the yes.

**To ai.nvim**, when ai-desktop does not run and ai.nvim can be loaded (`pcall(require, "ai")`, no hard dependency):
the task as one prompt in the scratch buffer `tasks://agent/<id>`; `mode=run` sends it after a question and puts the
answer below it (one answer, no tools). A message says that ai.nvim stands in. Without either: a message that names
what is missing (`ai-desktop is installed but not running: start it`).

### `:Tasks attach <id> <file> [name=<file name>] [kind=video|image|screenshot]` / `attach <id> from=clipboard|latest [dir=<folder>]` / `task folderize <id>`

A task may be a folder `tasks/<slug>/<slug>.md` that holds assets (concept section 12.2).
`attach` copies the file into `<slug>/assets/` -- a plain task file becomes a folder task
first -- and puts the Markdown link (`![name](assets/name)` for images) at the cursor of the task when it is open
in a window, else in the `+` register.
`kind=video|image|screenshot` puts the copy into the folder of its kind below it (`assets/videos/`,
`assets/images/`, `assets/screenshots/`), and the link names that folder; without `kind=` a file lies in `assets/`
itself. Assets attached before stay where they are.
`name=` renames the copy; an asset that already exists is never replaced. Spaces in the file
name become hyphens, and names Windows treats as devices (`nul`, `con`, ...) are refused. The
file argument is resolved once, by the composer (`~`, `$VAR`, `%VAR%`) and never expanded a second time,
so `report[1].pdf` is that file, not `report1.pdf`, and a backtick in a name never reaches a shell.
A failed copy
leaves the task as it was (no half-made folder task). `folderize` converts a task without
attaching anything. Windows showing
the old task file follow it. `task new ... --folder` creates a folder task from the start.

**Screenshot in one step.** Instead of a file, `from=clipboard` stores the image on the clipboard as a PNG in
`assets/screenshots/` (a screenshot is a kind of its own; `kind=image` puts it into `assets/images/` instead), and
`from=latest` the newest image of the screenshot folders (`attach.screenshot_dirs`, default: the usual folder of
the system, e.g. `~/Pictures/Screenshots`; `dir=<folder>` for one call) -- only when it was modified within
`attach.max_age_s` seconds (default 300), otherwise nothing is attached and the message names the file, so a week-old
picture is never attached by guess. Without `name=` the copy is called `<slug>-YYYY-MM-DD-HHMM.<ext>`; a taken name gets
`-2`, `-3`; an existing asset is never replaced. The tools for the clipboard are detected (`powershell.exe` on Windows,
`pngpaste` on macOS, `wl-paste` or `xclip` on Linux); with none, or without an image on the clipboard, you get a message
and nothing is created. Example: take a screenshot, then `:Tasks attach lib.nvim/my-task from=clipboard`; the link lands
at the cursor.

```lua
require("tasks_nvim").setup({ attach = { screenshot_dirs = { "~/Pictures/Screenshots" }, max_age_s = 120 } })
```

### `:Tasks plan [<area>|all] [--for=<id>|--plan=<id>] [filters] [--ready] [--with-steps] [--format=md|tsv|ids] [--to=] [--force]`

The plan of the open tasks, computed from `blocked_by` alone (nothing new to write): what is **ready now**, the
**decisions by leverage** (how many tasks depend on each, transitively: the one that unlocks most comes first),
**stages** (every task in the earliest stage it can be in), the **critical path** (the longest chain, weighted by the
effort), an estimate line, and warnings (a cycle, a parked or unknown blocker). `--for=<id>` plans one task and
everything that has to be finished before it, across areas. The filters are those of `list`; `--ready` keeps only the
"ready now" part. A task that blocks a better one is ranked by that one's prio (`prio 3 -> 1 because of ...`); the
written prio is never changed. A cycle over `blocked_by` is reported with its members and left out of the stages, the
rest is still ordered. `--to=` is `buffer` (default), `clipboard`, `file:<path>`, `echo` or `mdview`.

More than `blocked_by` shapes the plan, all of it optional:

- **`after=[id, ...]`** is a soft edge ("should come after X"): it moves a task to a later stage, never makes it wait
  (it is still ready), never counts as leverage, and one that would close a cycle is dropped with a warning.
- **`order=2.5`** is a tie-breaker inside a stage, behind status and prio; a fraction slots a task in between without
  renumbering.
- Tasks of one stage that name the same file in `refs` are marked **`same-file`**: not parallel work, the order says
  which comes first. The stage says so.
- **`--plan=<id>`** draws the plan of a plan file (below): its tasks (`plan: <id>`), the stage order (`phase_order`),
  the goal, the status and the target in the head. **`--with-steps`** shows each task's `## Plan` steps and progress.
- **`--write=<file>`** replaces only the generated block of a hand-written document:
  `<!-- GENERATED:plan scope=<name> start -->` ... `<!-- GENERATED:plan end -->`. The rest of the file keeps its bytes
  and its line endings **line by line** (a document with mixed endings is not normalised); headings inside the block
  sit one level below the document's own, and the plan's summary is quoted (`> `), so a summary that reads like a marker
  cannot split the block. The block name is the plan's slug, the area, `for-<slug>` or `all` (`--scope=<name>` picks
  another); `--check` writes nothing and says whether the block is out of date. Blocks are not part of `check` or CI.
  The path is literal (`~`, `$VAR` are expanded, `[1]` is no wildcard) and a symlink is written **through**.
  - The start marker **records how the block was made**: the target (`plan=<id>`, `for=<id>`, `area=<name>`), the
    view (`ready=1`, `steps=1`) and the filters (`status=doing`, ...), e.g.
    `<!-- GENERATED:plan scope=release plan=lib.nvim/release ready=1 start -->`. The refresh after a `done`, and
    `--check`, read it back and build the same block. A plain marker you wrote by hand is rewritten with these
    attributes by the first `--write`; one without them is resolved by its name (an area, an open plan's slug or id,
    `for-<slug>`, `all`) and, when two plans or tasks share that slug, **skipped with the candidates named** instead of
    refreshed from a guess. A filter value that cannot live on a marker line (a blank, `--`) is refused.
  - Several blocks of one scope are all refreshed; a marker inside a fenced code block (a document that shows the
    syntax) is no marker. A scope with a folder that could not be read is not written (a degraded copy of the plan).
  - Refreshing reads the vault once for all the blocks of a document and reads the file again right before it
    writes: an edit made meanwhile is kept, and a document that keeps changing is given up on with a message.

### `:Tasks planfile <area> <title...> [--areas=a,b] [--phases=a,b,c] [--gate=hard] [--target=<id>] [--status=]`

Creates `<area>/ROADMAP/plans/<slug>.md`, the plan file of an undertaking: the goal, the boundaries, the definition of
done and the names of the stages. It holds **no task list**: tasks join with `plan=<area>/<slug> phase=<word>` (so two
tasks edited on two machines never collide on a list). `--areas` names the areas whose tasks belong (`check` warns
about another), `--phases` the stages in order (a later stage follows the earlier one in the plan), `--gate=hard` makes
that a real rule (a task of a stage waits until the earlier stage is finished, and `list --ready`, `next` and the plan
all see it), `--target` the task that means "done". When the last member task is finished the plan is finished too (see
`:Tasks done`). Headless: `plan-new` (also `--links=url,url`: web addresses written to `links:`, http/https only). A plan
or project takes assets like a task: `attach <plan id> <file>` (or `folderize`) turns it into its folder form
`plans/<slug>/<slug>.md` with `assets/` beside the file, and finishing it moves the folder to the Backlog.

### `:Tasks path-new <area> <title...> [--areas=a,b] [--target=<id>] [--project=<id>] [--tags=a,b] [--status=] [--template=learning]`

Creates the learning path `<area>/ROADMAP/paths/<slug>.md` and opens it: the frontmatter of a plan without stages and
the sections `## Warum`, `## Lernpunkte` (the tree, [ENGINE.md](ENGINE.md), "Learning paths") and `## Notizen`;
`--template=learning` writes the sections of a learning path instead (goal and competence level, access, schedule,
sources with the column `Geprüft`, `## Lernpunkte` with the stages and the literature group named in its hints,
`## Level` with a commented example, self-check, open questions, repetition, `## Ergebnis schreiben`; the rules
`LP-06`, `LP-07`, `LP-11`, `LP-15`, `LP-18` of the rules vault). `--tags=not-on-workstation` (or `on-workstation`) goes to
every task promoted from the path. `--summary`, `--slug`, `--links`, `--icon` and `--cover` as for a plan; `--title=` names it when no words follow the area. A taken slug gets `-2`. Headless: `path-new` with the same
options. Then `:Tasks learn` shows the tree, and `:Tasks point` and `:Tasks promote` work on its points.

Headless `path-new <area> --from=<draft.md> [--slug=s] [--dry-run]` makes a whole path from one draft file (frontmatter,
sections, the tree, `## Level`): the slug as `path-new` gives the draft's `title`, `status: planning`, `created` and
`updated` added when the draft leaves them out, then the checks of `check` for a path (keys, marks, XP, arrows, relative
links, levels, images) as if the file were in place. Any error or warning refuses the draft and nothing is written; each
finding is a line `<severity>\t<code>\tline N: <message>` on stderr with the draft's line, then `refused\t<n> finding(s)`
(exit 1). A hint (`xp-missing`) does not refuse it. `--dry-run` prints `would-create\t<id>\t<path>` and writes
nothing; the frontmatter options (`--areas`, `--tags`, …) are refused beside `--from` (exit 2).

Headless `path <area>/<slug> [--format=text|json]` is the XP overview of a path while it is planned (`path_stats`):

```
path    Learning/neoload  planning  NeoLoad: Last- und Performance-Tests
points  100  open 100  learned 0  seen 0  dropped 0  without xp 0
xp      960  earned 0  open 960
stage   1  xp 60  points 7  open 7  without xp 0  Stufe 0 · Orientieren
level   1  50 XP  Erster Lauf  open  at point 7/100, stage 1: #skizze Ergebnis: ... (line 70)
level   2  25 % = 240 XP  Tacho Bronze  open  at point 25/100, stage 2: ...
level   done  path done  NeoLoad T 2 / P 2  open  at point 100/100, stage 7: ...
```

A stage is a root of `## Lernpunkte`, a point a leaf. The XP of a promoted point is the `xp:` of its task. The level
lines walk the points in their order and count each as learned in full (a dropped one is left out): a level is reached
at the first point where the sum comes to its threshold (a percent of the possible XP; a path without XP counts its
points). `at the start` is a threshold of 0, `not reachable` one the path cannot reach (more XP than it has, or XP on a
path without any). `without-xp` lines name the points that carry no XP. `--format=json` gives the same as one object
(`points`, `xp`, `stages`, `levels` with `at { index, line, key, label, stage }`, `without_xp`).

Headless `paths [<area>] [--project=<id>] [--format=tsv|json]` lists the open learning paths, one TSV line each: id,
status, `points <n>` (leaves of `## Lernpunkte`), `open <n>` and the progress in percent (of the XP when the path has
any, else of its points: learned one, seen one half, dropped out; the same figure the levels read). `--project=<id>`
lists the paths of one project and adds its finished ones (`done`, 100 %). An area group stands for its member areas.
`--format=json` gives `{ paths: [ { id, title, status, points, open, percent, done } ] }`.

```
tasks-desktop/rust-stack-a-rust-kern  doing     points 48  open 30  37 %  A · Rust-Kern
tasks-desktop/rust-stack-b-async-...  planning  points 41  open 41  0 %   B · Async und Server
```

Headless `plan-close <area>/<slug>` finishes a plan by hand (refused while a member task is open: the message names them)
and `project-close <area>/<slug>` a project (refused while a task of its own, or a plan or learning path that is not
parked, is open). A
project is also finished by `done`: when the finish closes its last plan, or is its last own task, and no other plan
(a parked one does not count) is open, the project is finished too (`project-closed` line; the parked plans stay and are
named). Closing a finished plan or project again prints `already`.

In the editor the same verbs are **`:Tasks plan-close <id>`** and **`:Tasks project-close <id>`**: the engine is asked
first (a dry run), a refusal names what holds it open and asks nothing, else a question (`--yes` skips it); the finish is
told like the one of `done` (the plan, and the project it was the last open plan of). `check` names what does not
finish by itself: `plan-no-open-task` (a plan in `doing` with no open task left) and `project-no-open-work` (a project
in `doing` with no open plan or learning path that is not parked and no open task of its own), both warnings with the
verb to run.

**A project, headless.** `project-new <area> "<title>" [--slug=s] [--areas=a,b] [--target=<id>] [--phases=a,b,c]
[--gate=hard] [--status=] [--summary=text] [--links=url,url] [--icon=] [--cover=] [--template=learning]` makes
`ROADMAP/projects/<slug>.md` (the write door: `project_new`). Plans join it with `project=<id>`, learning paths with
`path-new … --project=<id>` or `set <path> project=<id>`. `--template=learning` writes a curriculum of learning paths
(`LP-01`): `## Ziel und Abgrenzung` with the competence target, `## Lernpfade` with the generated overview block of the
project already in place (`<!-- GENERATED:plan scope=<slug> overview=<id> start -->`; `projects --of=<id>
--write=<the project file>` fills it with the table of its paths), `## Takt`, `## Definition of done` and
`## Entscheidungen`. It proposes no stages (a curriculum is ordered by its paths); `--phases` still sets some.

```sh
tasks project-new tasks-desktop "Rust-Stack der App-Familie" --template=learning --areas=tasks-desktop,appkit
tasks path-new tasks-desktop "A · Rust-Kern" --project=tasks-desktop/rust-stack-der-app-familie --template=learning
tasks projects --of=tasks-desktop/rust-stack-der-app-familie --write="$VAULT/tasks-desktop/ROADMAP/projects/rust-stack-der-app-familie.md"
```

`--write=` is a path of this machine (relative to the working directory), not of the vault.

**Projects, headless.** `projects [<area>]` lists the project files, one TSV line each: id, status, location, title, `plans <finished>/<all>`, `tasks <finished>/<all>`, `<n> d open` and `paths <finished>/<all> <n> %` (its learning paths, `project:` in the path file, finished ones from the Backlogs; the mean progress, a finished path at 100 %) (a project is listed in an area when it lives there or one of its plans does). `plans [<area>] --tree` puts the plans under their project, indented and with `stage <phase>`, projects first, the plans of no project after them; plain `plans` is unchanged. The filter **`--project=<id>[,<id>]`** of `list`, `plan`, `estimate` and `quickwins` keeps the tasks of those projects: in one of their plans, or their own (`project:`); it narrows together with the other filters. `new --project=<id>` makes a task of the project itself (instead of `--plan=`). `:Tasks list|plan|estimate|quickwins ... --project=<id>` take the same filter, and the dashboard shows it as the chip `[project: <id>]`. With ONE project, `plan` and `estimate` draw it like a plan file: the head (title, status, goal, stages from its `phase_order`) above the tasks of its plans and its own (`# Plan: project <id>`); an unknown project is an error there, an empty answer in `list`. A block written with `plan --write` records the filter only, without the head. **`projects --of=<id> --write=<file> [--scope=<name>] [--check]`** puts the plans of one project into the marker block `<!-- GENERATED:plan scope=<name> overview=<id> start -->` of a hand-written document: a table with stage, plan, status, open tasks and open days, in the order of the project's `phase_order`, finished plans included, then a table of its learning paths (path, status, points, open points, progress; finished ones at 100 %; a project with paths and no plans shows no table of plans), plus the count of the project's own open tasks. The marker records `overview=<id>`, so the refresh after a finish (`done`) keeps the table current like any other block, once the document is named in `chain.marker_docs` (or `$TASKS_MARKER_DOCS`); without that, run the command again; `--check` writes nothing and answers `stale` (exit 1) or `current`.

### `:Tasks next [<area>|all] [--n=3] [--actor=cdx|me|pair|none]`

What to start next: the best **ready** task and why, with a small dialog (`Not now` first, `Open <id>`, `Show another`).
The order is fixed: freed by the task you just finished, then the same area, then the vault; `doing` before `open`
before `decision`; the effective prio; the earlier `due` date (undated after dated); the return on effort; the smaller effort; the id. Tasks written `cdx` are not
"your next task": they are listed apart ("an AI session could take ..."); `--actor=cdx` asks for that queue instead.
The headless `tasks next --not-category=learning` (and `not_category` of the contract) leaves the ready tasks of those
categories out, from the pick, the alternatives and the `cdx` queue, and says how many (`left_out`; the text answer prints a line `left_out: N ready task(s) ...`, one word before the colon like every other line).
When there is nothing, the answer says which kind of nothing: **never** "all done" while work is only waiting
("Nothing can be started. Still open: 4 for you, 6 blocked, 3 parked."). Parked tasks that name what they wait for are
broken down: "30 parked (25 waiting for mac, 3 for licence)".
The headless `next` (text) also lists the **reminders that are due** -- `remind: <id> <title> <date>` for the open
tasks, oldest first, and one line with the number of finished tasks that carry one (`list --done --reminders` lists
them) -- so a session that asks what to do next also sees what is to be looked at again. `--today=YYYY-MM-DD` pins the
day they are judged by (anything else is a usage error, exit 2). Only `next` lists them: `next --format=json`, the
dialog after `done` and `done` itself do not.

### `:Tasks estimate [<area>|all] [--for=<id>] [filters] [--walk]`

Sums of effort and value, always saying what they are made of: "22 d from 17 of 20 (range 14-31 d) · value 61 ·
roi 2.8 · me 8.5 d / cdx 13.5 d / unclear 3 -- estimate from the scale, not a promise". The range puts every size at
its low and its high end (a T-shirt size is not a number). The return on effort counts only the tasks that have both
numbers. Quick wins (value 4 or more, effort S or less) are named. `--walk` goes through the tasks that miss an effort
or a value, asks for them one by one (`Skip` first; `Stop`, and a dismissed dialog (Esc), end the walk and keep what was given)
and writes everything in one batch.

### Tasks lists

A **list** is a filter combination plus a sort order (and optionally one area) under a name. Its fields are the option
words of `:Tasks list`, written as strings: `status prio effort kind category severity value actor tag sheet stale plan phase`,
the booleans `blocked reminders overdue unestimated stale_refs quick_win`, `readiness` (`ready` or `waiting`), `sort`, `area` and a one-line
`desc`. A list is checked by the same parser as the command line and a complaint names the list; an unknown key is an
error, never ignored.

Three sources, the later one wins by name:

1. **built in**: `quick-wins` (the quick-win definition, best return first), `small-and-important` (prio 1-2, effort S
   or less, startable now), `unestimated` (missing an effort or a value), and the three groups of the acceptance (the
   view "Abnahme" of tasks-desktop): `abnahme-inbox` (`--sheet=inbox`: the test sheet is green by machine and waits for
   your judgement), `abnahme-manual` (`--sheet=manual`: a sheet to do by hand) and `abnahme-by-hand`
   (`--tag=needs-live-test --sheet=none --status=open,doing,decision`: a live check without a sheet - real accounts,
   another machine, use over days). The worst sheet decides `inbox` and `manual`: a task with a red and a waiting sheet
   is `red` here, while the acceptance view shows it with its waiting points and the red sheet named;
2. **saved**: a small state file (`stdpath("state")/tasks/lists.json`, or `$TASKS_LISTS_FILE`), written from the
   dashboard (`gl`) or by `tasks lists save`. A saved list may replace a built-in one;
3. **`setup({ lists = {...} })`**: your config, which cannot be changed or deleted from the dashboard or the CLI (edit
   the config). A saved list of the same name is shadowed and `:checkhealth` says so; a later `setup()` replaces the
   whole set.

```lua
require("tasks_nvim").setup({
  lists = {
    ["small-and-good"] = { effort = "<=S", value = ">=4", sort = "roi", desc = "worth doing in an hour" },
    ["my-bugs"] = { kind = "bug", actor = "me", status = "open,doing" },
  },
})
```

Running one: `:Tasks list --list=small-and-good` opens the dashboard on it; every option you type on top wins over the
list (`:Tasks list --list=my-bugs --prio=1`); `--list=` also works for `plan` and `estimate`, which take what a list
selects but not how it orders (`sort` is left over). A list that sets something the command has no use for (`readiness`
for `estimate`, `waiting` for `plan`) or names an area the vault does not have is an **error**, never a quietly wider
answer. `:Tasks lists` opens a menu of all of them. A saved file that cannot be read is never written over (the dashboard menu says why), and a
single broken list in it is skipped and named, the rest stays.

Headless: there is no `setup()`, so the CLI knows the built-in and the **saved** lists (the state file), not the ones of
your spec; `tasks lists save` is how a list gets there. Two Neovim instances saving at the same moment can lose one of the
saves (the last writer wins), the file itself is always whole.

```sh
nvim --headless -u NONE -l scripts/tasks.lua lists                                  # name, source, what it selects
nvim --headless -u NONE -l scripts/tasks.lua lists save worth --effort='<=S' --value='>=4' --sort=roi --desc='worth an hour'
nvim --headless -u NONE -l scripts/tasks.lua lists show worth                       # the equivalent command line
nvim --headless -u NONE -l scripts/tasks.lua list @worth --prio=1                   # run it, with an override
nvim --headless -u NONE -l scripts/tasks.lua lists rename worth worthy
nvim --headless -u NONE -l scripts/tasks.lua lists delete worthy
```

### `:Tasks waits [<area>|all]` and `:Tasks release <key> [--dry-run] [--yes]`

Tasks that cannot be worked on because something outside is missing are parked **with a reason**
(`:Tasks set <id> waits_for=<key>`, see [`set`](#tasks-set-id-keyvalue-)). `waits` is the overview: per key the number
of parked tasks and their areas (most tasks first), then the parked tasks without a reason and the total.

```
mac: 25  (cascade.nvim, lib.nvim)
licence: 3  (lib.nvim)
parked without a reason: 2
parked: 30
```

`:Tasks list --waits-for=mac` lists the group (in the dashboard: the `waits_for` entry of the `f` menu, with the keys in
use and `none`), `--waits-for=none` the tasks parked by choice. A parked task shows its reason as `[waits: mac]` in the
dashboard, as ``(wartet auf `mac`)`` in the generated `ROADMAP/TASKS.md` and as `waits: mac` in the plan's note column.

`release <key>` brings the whole group back when the thing is there: every parked task with `waits_for: <key>` gets
`status: open`, loses the key and gets `updated`, the index of every touched area is written once. It asks first and
names the number of tasks (`--yes` skips the question); `--dry-run` only names them. A task that changed since the list
was read is refused, not overwritten, and named. Headless:

```sh
nvim --headless -u NONE -l scripts/tasks.lua waits                  # mac<TAB>25<TAB>cascade.nvim,lib.nvim ...
nvim --headless -u NONE -l scripts/tasks.lua waits --format=json    # the tasks.waits document
nvim --headless -u NONE -l scripts/tasks.lua list --waits-for=mac
nvim --headless -u NONE -l scripts/tasks.lua release mac --dry-run  # would-release<TAB><id> per task
nvim --headless -u NONE -l scripts/tasks.lua release mac            # released<TAB><id> per task; exit 1 when none waits
```

### `:Tasks quickwins [<area>|all] [filters] [--to=] [--format=md|tsv|ids] [--by-actor] [--paths] [--report=<file>]`

The quick wins: a task with **both** numbers written, a value of at least `quick_wins.min_value` (default 4) and an
effort of at most `quick_wins.max_effort` (default `S`), best return on effort first. The report also names what the
rule cannot see, never as a quick win: the small tasks **without a value** ("one number away") and the high-value tasks
**without an effort**. By default only what can be picked up is looked at (`--status=open,doing,decision`; a parked or
blocked task is not offered, name it with `--status=`; `--waits-for=<key>` asks for parked tasks and so leaves the default out). `--value`, `--effort` and `--quick-win` do not exist here: they
are the definition. `--by-actor` splits the table into "for me", "pair", "for an AI session" and "unclassified",
`--paths` adds a column with the absolute path of each task file. `--to=` delivers it like `list` does (default: a scratch
buffer).

`--report=<file>` writes the Markdown to a file instead. The file starts with a generated-comment and is replaced by the
next run; a file at that path that this command did not write is **never** overwritten (an error). Headless:

```sh
nvim --headless -u NONE -l scripts/tasks.lua quickwins                       # tab-separated: id prio effort value roi actor title
nvim --headless -u NONE -l scripts/tasks.lua quickwins --format=md --by-actor --paths
nvim --headless -u NONE -l scripts/tasks.lua quickwins --min-value=3 --max-effort=M --report=quickwins.md
```

`--min-value` and `--max-effort` override the thresholds for one headless run. To keep a different definition, set
`setup({ quick_wins = { min_value = 3, max_effort = "M" } })`: every place that names quick wins (`:Tasks estimate`, the
plan header, `--quick-win`, this report) follows it.

### Headless: `intent` (an intent from another app)

```
nvim --headless -u NONE -l scripts/tasks.lua intent finding.json          # what it would do
nvim --headless -u NONE -l scripts/tasks.lua intent finding.json --yes    # make the task
cat finding.json | nvim --headless -u NONE -l scripts/tasks.lua intent - --yes
```

Takes an intent `wkd-intent/1` (`tasks.new` from a testing finding, `tasks.show`), checks it as untrusted input and prints
`would_create`, `exists` (a task holds the ref `testing-finding:<fp>` already), `shown`, `not_found` or, with `--yes`, `created`.
Details and limits: [ENGINE.md](ENGINE.md#taking-an-intent-wkd-intent1).

### Headless: `history` (the overview figures over time)

```
tasks history [<area>] [--since=YYYY-MM-DD] [--until=YYYY-MM-DD] [--resolution=day|week] [--format=tsv|json]
tasks history record [--dry-run]
tasks history backfill [--since=YYYY-MM-DD] [--until=YYYY-MM-DD] [--dry-run]
```

`history` prints one line per day (or week) of the window, by default the last 90 days: the day, `*` for a day a row
was written on (else `-`), then open, ready, waiting, stuck, decision, parked, with value, with effort, the sums of
effort days and value, and what the files say about the day (finished, created). A `-` in a figure is a day before the
first row. `--format=json` is the `tasks.history` document.

`history record` writes down the figures of today: one row per area whose figures changed since its last row, in
`<vault>/_Telemetry/history/YYYY-MM.jsonl` (the folder is made on the first run). After that, `tasks index` without an
area does the same on every run (`--no-history` leaves it out). `history backfill` fills the days before today that
have a commit and no row from the history of the vault's repository; the progress goes to stderr, the repository is
not touched. Details and the reasons: [ENGINE.md](ENGINE.md#the-series-of-the-figures-_telemetryhistory).

### Headless: `claim` and `unclaim` (reserve a task while you work on it)

```
nvim --headless -u NONE -l scripts/tasks.lua claim lib.nvim/the-task --by=cdx-chat-3 --for=2h
nvim --headless -u NONE -l scripts/tasks.lua unclaim lib.nvim/the-task --by=cdx-chat-3
nvim --headless -u NONE -l scripts/tasks.lua next --by=cdx-chat-3
```

`claim` reserves the task (and sets it `doing`); another name is refused with the owner's name, the same name renews, an expired
claim is taken over. `--force --note=<why>` passes a claim of somebody else. `set`, `done`, `attach` and `folderize` take
`--by`, `--force` and `--note`; `next` takes `--by` and leaves out what others work on. `show` prints `claim: <by> since ... until ...`.
`unclaim` is the verb for giving back (`release <key>` belongs to the parked tasks). `list --claimed=own|foreign|none` lists the tasks by
their claim, and the dashboard marks a claimed line (`[claim: mine]`, `[claim: <who>]`). Details: [ENGINE.md](ENGINE.md#claims).

### Headless: `agent-brief` (the brief for an AI agent)

```
nvim --headless -u NONE -l scripts/tasks.lua agent-brief                          # Markdown
nvim --headless -u NONE -l scripts/tasks.lua agent-brief --by=ai-desktop:job-42   # the claim name of the examples
nvim --headless -u NONE -l scripts/tasks.lua agent-brief --format=json            # tasks-agent-brief/1
nvim --headless -u NONE -l scripts/tasks.lua agent-brief --repo=<dir> --format=json   # with the checks of that repository
```

The text an agent (ai-desktop, ai.nvim) gets as a tool description when a job comes from the tasks family: the workflow
(`claim` before the work, `set`/`new` with `--by`, `done --commits --done-in`, `unclaim` to give it back, a foreign claim
is a stop), the allowed values of every field and the command reference. Nothing in it is written twice: the values come
from the engine's model and the reference is the `--help` text of this CLI, so a new command or category reaches the
brief without an edit. It names `brief_version`, the contract version (`contract_schema`, as in `call hello`) and the
engine version; `--format=json` carries the same Markdown in `markdown` next to those numbers, in canonical key order, so
a caller compares the versions of the brief it holds and asks for a new one. `--by` (default `ai-desktop:<job>`, a
claim name of up to 64 characters) only fills the examples. It reads no vault. Every brief names the staging rule of a
shared checkout: only own files by path, never `git add -A`, `git add .` or `git commit -a`.

`--repo=<dir>` (the checkout the agent works in) adds the section "Checking": how that repository is checked before
commit and push, never invented.

- With a `.testing.lua` (testing.nvim): after every commit `scripts/test.sh ci commit <sha> --quick -- --cached` (the
  verdict on the first line: `CLEAN`, `KNOWN-RED`, `FLAKY` go on, `REGRESSION` is fixed at once); before the push
  `git pull --rebase origin main`, `git log origin/main..HEAD` and once the final run
  `scripts/test.sh ci commit HEAD --base=origin/main --wsl -- --cached` (`--wsl` on Windows only), then
  `git push origin HEAD:main`. With `ci.workflow.land = true` `scripts/test.sh ci land` replaces the final run and the
  push (the hosted CI checks it, main moves only when green). Without `scripts/test.sh` the commands start with
  `testing`. The file is loaded in an empty environment (no `vim`, `os`, `io`, `require`) with an instruction budget, so
  building the brief starts nothing; a file that needs more is read as text for `land = true`.
- Without it: the commands of the fenced blocks in the section "Vor jedem Commit" (or "Before every commit") of the
  repository's `CLAUDE.md`, then pull, `git log origin/main..HEAD` and the push. Without such a section: no checks.

`--format=json` then carries `checks`: `source` (`testing`, `claude-md` or `none`), `land`, `per_commit` (with `<sha>`
to fill in), `before_push`, `commands` (from `CLAUDE.md`), `sync`, `review` and `push`, the exact command lines, for a
caller that allows its agent to run just these. Neither the Markdown nor `checks` names the directory.

### `:Tasks claim <id>` and `:Tasks unclaim <id>`

The two verbs of the section above in the editor, on the same engine: `:Tasks claim lib.nvim/the-task for=2h by=me@host [note=<why>] [--renew] [--force]`
and `:Tasks unclaim lib.nvim/the-task [by=<name>] [status=open|parked|decision] [note=<why>] [--force]`. Without `by=` the editor is
`cdx:<8 characters of $CLAUDE_CODE_SESSION_ID>` inside a Claude Code session, else `<user>@<host>`. The result is one line (`claimed`,
`renewed`, `unclaimed`); a refusal names the owner. The buffers of the task are brought up to date.

### `:Tasks done <id> [done_in=...] [commits=repo@sha,...] [date=YYYY-MM-DD] [--yes]`

`commits` is the list of every commit made for the task, `repo@sha` each (7-40 hex digits),
so a finished task can be traced back to its code afterwards. `commits=` adds to the task's own
`commits` (a commit named twice is listed once); `:Tasks set <id> commits=[...]` replaces the
list at any time, and `tasks check` reports a malformed entry (`bad-commit`). `done_in` stays
free text.

A finished task is entered into the Backlog index `<area>/Backlog/README.md`; an area that has none yet (a new one) gets the file
with that first row, as closing a plan does.

**A routine** (`repeat: 8w`, see [ENGINE.md](ENGINE.md#routines-repeat)) starts its next round when it is finished: the
finished round goes to `Backlog/` as always, and a new open task with the slug `<base>-<due>` takes its place. The CLI
prints `next-round<TAB><id><TAB><due>`, the editor says "next round of ...". `tasks done <id> --last` (headless) finishes a
routine for good: no next round (or take `repeat` away with `set <id> repeat=` first). A ladder (`repeat: 1w,4w,12w`)
ends by itself after its last round (`routine-ended`), and a finish that a routine waited for (`repeat_after`) starts
it (`routine-started <id> <due> after <ref>`); see [ENGINE.md](ENGINE.md#routines-repeat).

Rule R6, after a confirmation (`--yes` skips it): `status: done`, `done_in`, `commits`; the file moves
to `Backlog/FEATURES/` (`feature`, `idea`, `research`) or `Backlog/TASKS/` (`task`, `bug`, no
kind) as `YYYY-MM-DD_<slug>.md`; its row goes on top of that section of `Backlog/README.md`;
the index is regenerated. On any failure the files involved are restored byte for byte.
Windows showing the open file follow it to the new path (an unchanged buffer is replaced,
one with unsaved changes is left alone and reported). Running it for an already finished
task says so and changes nothing.

Finishing sets a chain in motion, each step on its own (a failure after the finish never undoes it, it is a
message): the open steps of the task's own `## Plan` are **ticked** (a step marked `(dropped)` or `(entfaellt)` stays
open; the ticks are written with the finished copy, so the rollback covers them), a **plan file** whose last member this
was is finished (moved to `Backlog/FEATURES/`, "Plan x is done: 12 tasks, estimate 9.5 d, finished in 14 days"), and
the **generated blocks** of the documents named in `setup({ chain = { marker_docs = { ... } } })` are refreshed (only
those files; the block of a finished plan becomes its closing line). The headless CLI has no `setup`: it reads the same
list from `$TASKS_MARKER_DOCS` (comma separated). A plan counts as finished when no task with `plan: <id>` is left that
is not `done` -- valid or not: a mistyped `status:` keeps the plan open; a scan that could not read every folder closes
nothing and says so. One id namespace holds plans, tasks and Backlog files: a plan whose id an open task or a finished
item already has is not finished (and `plan-new` / `new` skip such a slug).

After the finish a small dialog names the tasks it freed and the next task to start (see `:Tasks next`); with
`setup({ next = { popup = false } })`, or without a UI, the same text is a plain message. A task that waited only on
this one and still says `status: blocked` is offered to be set to open (a question, never silently). In the
dashboard, `D` on several marked tasks shows ONE dialog after the whole stack.

### `:Tasks reopen <id> [status=open|doing|blocked|parked|decision] [--yes]`

The way back from `done`, never by hand: the finished file goes from `Backlog/<bucket>/` to `ROADMAP/tasks/` with
`status: open` (or the status given), `done_in`, `remind` and `waits_for` (unless it comes back parked) are dropped, its
row leaves `Backlog/README.md` and the index of the area is written. `commits` and the rest of the file stay: they are
the history of the task. A milestone that this task had reached goes back to `doing`. It asks first (`--yes` skips the
question); `<Tab>` offers the finished tasks only. A folder task is refused (move it back by hand), so is a name an
open task or plan has taken.

Headless it is `tasks reopen <id> [--status=]` (the operation `reopen` of `tasks-ops/1`): the id as `show` takes it,
or the name of the finished file (`<area>/2026-11-18_<slug>`, also with `.md` or as the path below the vault). It
prints `reopened<TAB><id><TAB><file>` and `index<TAB>...`; a task that is open already prints `already-open<TAB><id>`
(exit 0); a refusal is exit 1, a wrong call exit 2.

```
tasks reopen lib.nvim/fix-parser                   # reopened<TAB>lib.nvim/fix-parser<TAB>lib.nvim/ROADMAP/tasks/fix-parser.md
tasks reopen lib.nvim/2026-11-18_fix-parser --status=doing
```

### `:Tasks template [--to=clipboard|buffer|file:<path>] [--with-plan]`

The task file template (every field, visible placeholders; `--with-plan` adds the optional `## Plan` section with
checkbox steps) into the `+` register (default)
plus a notification. Without a working clipboard provider it opens in a buffer instead and
says so.

### `:Tasks open <id|part of a name>`

Opens the file of an open task, or its finished copy in `Backlog/`. The full id (`area/slug`) opens as it
always did; anything else is looked up (`tasks_nvim.match`, the engine, so a front end other than the command
can ask the same question):

- the slug is matched first (equal, then its start, then anywhere in it), then the title of an open task;
  case does not matter; an open task comes before a finished one of the same closeness;
- `area/part` looks in that area only, `area/` alone lists all of its tasks;
- one hit, or one slug that is exactly the text, is opened; several are offered in a list (`vim.ui.select`);
  none is told, and when some slugs come close they are offered to pick from ("did you mean");
- `<Tab>` completes a slug without its area where it names one task only.

`preview` and the other verbs still take a full id.

### `:Tasks preview <id>`

The same file (an open task, else its finished copy) rendered in the browser by mdview.nvim:
see [Browser preview](#browser-preview-mdview).

### Browser preview (mdview)

`task preview <id>`, `tasks ... --to=mdview` and the dashboard keys (`gp`, and "Preview in
browser" in the `e` menu) put the rendered Markdown in the browser through
[mdview.nvim](https://github.com/WKDSteve/mdview.nvim). The wire is `ui/preview.lua`:

- **A task file** is opened as it is (`:edit`, then `:MDView start <file>`, the path handed over as
  one argument, so a space, `#`, `%` or `'` in it survives), so edits show up in the preview live.
  Nothing is copied and nothing is written to the vault.
- **A list export** (`--to=mdview`, `--format=md` only; `--format=csv` is refused) is rendered to
  Markdown, written to a temp file `tasks-<scope>.md` (`-2`, `-3` on a name clash; the scope is the
  area or `all`) in Neovim's per-session temp directory, and opened the same way. The buffer is
  unlisted. The file is deleted when its buffer is deleted, wiped or unloaded (a plain `:bdelete`
  included; a reload with `:edit!` keeps it; retrying a few times, Windows
  holds a file for a moment) and, for whatever is left, when Neovim quits; Neovim removes its
  temp directory on exit anyway. A temp location inside the vault is refused.
- **mdview.nvim is a soft dependency.** The check is "the `:MDView` command exists (a lazy stub
  counts) or `require("mdview")` works"; otherwise the command says
  `mdview.nvim is not available ...` and writes nothing. No `require` happens at load time.
- **Frontmatter:** a task file starts with flat YAML. mdview.nvim renders a leading frontmatter
  block as a two-column table (before that, it showed a rule plus one big heading made of the
  metadata lines -- that needs the renderer of mdview.nvim from 2026-10-04 on, i.e. a rebuilt
  or newly released WASM bundle). The generated `ROADMAP/TASKS.md` has no frontmatter and needs
  nothing.
- **Seams** (for specs and replacement): `ui.preview.probe` (is mdview there?),
  `ui.preview.opener` (open + start the preview, returns `ok, err`),
  `ui.preview.temp_root` (temp directory).

### The learning tree: `:Tasks learn`, `point`, `promote`, `unpromote`

They work on a buffer that holds a learning path (`<area>/ROADMAP/paths/<slug>.md`) or a task with `## Lernpunkte`
(`tasks_nvim.ui.learn`; the tree itself: [ENGINE.md](ENGINE.md), "Learning paths").

- `:Tasks learn [toggle|on|off]` puts the view on the buffer (or takes it off): the progress of every parent and of the
  whole tree on its heading as virtual text (`7 gelernt · 2 angeschaut · 1 entfällt · 3 offen`), a fold per parent
  (`foldmethod=expr`, all open at first; `off` gives the window its fold options back), and a placeholder line
  `[image] assets/...` below each point with an image (`(missing)` when the file is not there). It redraws while you
  type. `setup({ learning = { auto = true } })` puts it on by itself when a path or a task with `## Lernpunkte` is
  shown.
- `:Tasks learn image` shows the image of the point under the cursor: through images.nvim in the terminal, else the
  whole file in mdview.nvim's browser preview, else its path as a message. Only a file below the `assets/` of the path
  or task is shown.
- `:Tasks learn follow` opens the task the point under the cursor was promoted to (`→ <id>`).
- `:Tasks point [next|open|learned|seen|dropped|blocked] [reason...]` changes the mark of the point under the cursor
  (`next`, the default: `[ ]` -> `[x]` -> `[~]` -> `[-]` -> `[ ]`). `seen` and `dropped` need a reason: the rest of
  the line, or a question that offers the old one (cancelled: nothing changes). A path buffer without unsaved changes
  is written on disk through `paths.point` (under the file's lock, refused when the file changed below the buffer) and
  reloaded; a task file, or a buffer with unsaved changes, is changed in the buffer, write it yourself. A parent has no
  mark of its own, and a promoted point is refused: its state belongs to the task (`done` writes it).
- `:Tasks promote [<area>/<slug>#<key|n>] [--area= --title= --actor= --dry-run --no-index]` makes a task of the point
  (the one under the cursor when no point is named; the buffer must be written first): its subtree moves into the
  task, the point's line becomes `… → <id>`, the container's buffers are reloaded and the new task opens.
  `:Tasks unpromote [<area>/<slug>#<key|n>] [--dry-run --no-index]` takes it back while the task holds no work of its
  own. The same rules as the CLI's `promote` / `unpromote` ([ENGINE.md](ENGINE.md), "Promoting a learning point").
- XP, level and rewards ([ENGINE.md](ENGINE.md), "XP, levels and rewards") are drawn quietly: `25 XP` at the end of
  each leaf that has XP (a promoted one shows the `xp:` of its task, read again when the buffer is read or written),
  and on the heading after the progress `120 / 300 XP · Level 2 (Einsteiger) · Belohnung offen: Kino`. A level
  reached while the view is on says so once, in one line (`[tasks] Level 2 erreicht: Profi`), no popup.
  `setup({ gamification = false })` hides all of it; the progress stays.
- `:Tasks xp [<n>|clear]` sets the XP of the point under the cursor (`{xp=N}` in its line; `clear` removes it). Without
  a value it asks, filled in with the point's own XP or the engine's suggestion. It is written like `:Tasks point`. A
  parent sums its children, and a point whose task carries `xp:` is changed in the task.
- `:Tasks reward <n|done> [--undo]` marks the reward of level `n` (or of the line for the whole path) in `## Level` as
  granted, "gegönnt" (`[x]`), or open again. It works only in a path buffer without unsaved changes
  (`paths.set_reward`, under the file's lock).

No key is bound unless `keys.learning` names one ([BINDINGS.md](BINDINGS.md)).

### `:Tasks folder <area> [folder] [--action=files|grep|smart] [--list] [--to=]`

A picker over the files of **one folder of one area**. `folder` is `tasks`
(`ROADMAP/tasks`), `roadmap` (`ROADMAP`), `backlog` (`Backlog`), `handover` (`handovers`),
`notes` (`NOTES`) or `all` (the whole area, the default). A folder the area does not have is
reported and no picker opens.

It calls `pickers.command.dispatch(action, { roots = { <folder> }, prompt = ... }, engine)` of
[pickers.nvim](https://github.com/WKDSteve/pickers.nvim) when that plugin is installed, so the configured
picker engine is used; `--action=grep|smart` searches file contents. `--list` (or `--to=`) delivers the list of
files, relative to the folder, instead of opening a picker.

**Limitation and fallback.** A pickers.nvim *collection* cannot express "one area, one
subfolder" (a collection offers "pick one subfolder of this directory"), so `open` does not
use one. Without pickers.nvim it falls back to a plain `vim.ui.select` over the folder's
`*.md` files: no content search, and `--action=grep|smart` is answered with that hint.
Full-text search over the whole vault is a job for your picker's own grep on the vault folder.

### `:Tasks meeting list|open|new|close`

The meetings of the vault (`<area>/MEETINGS/`) in the editor. `list [<area>] [--section=]` is a
`vim.ui.select` over the meetings, the planned ones from yesterday on first (the earliest first),
then the others (the latest first); a line names day and time, status, title, place or service
and id; the one picked opens, at the section `--section=` names (`agenda`, `teilnehmer`,
`unterlagen`, `protokoll`, `beschluesse`, `folgeaufgaben`, `ergebnis`, or the English words).
`open <id> [--section=]` does the same for one id. `new <area> <line...>` reads the rest of the
line with the quick capture (a day such as `Mo`, `morgen` or `24.11.`, a time or range, a
duration, `ganztägig`, an address, `@place`, `#area/task`, `!-15m`; every other word is the
title), makes the meeting through the write door and opens it at its agenda. `close <id>
[--result=]` marks it done (at any time; the message says when it has no result). The headless
twins: `tasks meeting new|set|close|followups|attend|show|parse` and `tasks meetings`.

### Headless: `import --from-rules` and `bootstrap` (rules.nvim)

A run of [rules.nvim](https://github.com/WKDSteve/rules.nvim) written as a work list (`rules-work-list/1`, see
`docs/WORK-LIST.md` there) becomes tasks of an area. The work list is the only coupling: tasks.nvim never loads
rules.nvim and works the same without it.

```sh
# in the project, with rules.nvim installed: the work list of the review gate
nvim --headless -c 'lua io.stdout:write((require("rules").run_gate_work_list("review", vim.fn.getcwd())))' -c q > review.json
nvim --headless -u NONE -l scripts/tasks.lua import my.nvim --from-rules=review.json          # what it would do
nvim --headless -u NONE -l scripts/tasks.lua import my.nvim --from-rules=review.json --apply  # do it
nvim --headless -u NONE -l scripts/tasks.lua bootstrap new.nvim --from-rules=- --apply < review.json
```

- **A dry run is the default.** Every rule gets a line: `would-create <id> <rule> <title>`, `exists <id> <rule>`,
  `done <id> <rule>` (a finished task, not opened again), `waived - <rule> <reason>`, `passes <id> <rule>` (the rule
  passes now and the task may be finished), `invalid - <rule> <why>`; the last line counts them. `--apply` writes,
  `--dry-run` says the default out loud. The area is always named on the command line, never taken from the list
  (a note says so when the checked project and the area have different names).
- **One task per rule that fails or nobody judged** (`fail`, `unchecked`: a manual rule, or a check that could not run):
  title `<rule id>: <the rule's heading>`, `rules: [<id>]`, `category: [ruleset]`, prio from the severity
  (`critical` 1, `recommended` 2, `nice-to-have` 3), effort `S` for an automated rule and `M` for a manual one, `refs`
  with the anchor `rules-target:<project folder>` and the findings (`file:line`, at most 20). The body holds the rule's
  text, where it is (its file relative to the ruleset), the run, the findings, and the acceptance as a checklist.
  `--lang=en` writes English headings.
- **Idempotent:** a task of the area (open or finished) that names the rule in `rules:` and the same project in `refs`
  (or no project at all: a task written by hand) means no new one. A waived rule gets no task; an expired waiver no
  longer waives, so its rule fails and gets one, with a line about the waiver.
- **What comes from the document is checked first:** another schema, another version, broken JSON, more than 4 MiB or
  2000 entries refuse the whole list; a rule id or project name that is not a plain word is refused (its entry is
  `invalid`); control and ANSI sequences are taken out, a heading in the rule's text is escaped, and no absolute path
  reaches a task (a finding outside the project is counted, not named; a rule's file is named relative to its ruleset).
- **`bootstrap <area>`** makes the area first: `ROADMAP/tasks/`, `Backlog/FEATURES/`, `Backlog/TASKS/`, `README.md`,
  `Backlog/README.md` and the index `ROADMAP/TASKS.md`, whatever is missing (nothing existing is overwritten), then
  imports `--from-rules` if given. Its dry run lists `would-make <path>` and the tasks.

### Headless: `init-vault` (a new vault)

```sh
nvim --headless -u NONE -l scripts/tasks.lua init-vault ~/my-vault                  # what it would make
nvim --headless -u NONE -l scripts/tasks.lua init-vault ~/my-vault --apply          # make it
nvim --headless -u NONE -l scripts/tasks.lua init-vault ~/my-vault --area=work --lang=en --apply   # --force: into a folder that has other files
```

The folder is the positional argument, not `--vault`. It gets a `README.md`, a first area (`Inbox` unless `--area`
names another, laid out as `bootstrap` does) and, when that area has no task yet, an example task in German or English
(`--lang`). Nothing that exists is overwritten, a second run makes nothing; a drive or filesystem root, a file and an
area name that is no folder of a vault (`TOOLS`, `_x`, `../x`) are refused, and so is a folder that has files but is no
vault (no `README.md`, no area: a home or project folder named by mistake) unless `--force`. Point `--vault=` or `$TASKS_VAULT` at the
folder afterwards. To look around first, `examples/vault` in this repository is a small finished vault (two areas,
open, blocked, decision and finished tasks, a plan): `--vault=examples/vault`.

## `:TasksVault`: the vault itself

`:Tasks` works on tasks; `:TasksVault` works on **where they live**: open, copy, paste and search the Backlog (or
another part) of an area, make a note in it, create a vault. It is a second command so that "the vault" and "the tasks
in it" stay apart. The grammar is verb-first, like `:Tasks`.

```
:TasksVault <verb> [<area>] [<part>] [--rel] [--file]
```

`<area>` is a folder of the vault; a prefix is enough (`lib` for `lib.nvim`) as long as it is unique. Left out, it is the
area of the current buffer (a file inside the vault, or inside a repository folder named like an area), else a picker.
`<part>` is `backlog` (default), `features` (`Backlog/FEATURES`), `tasks` (`Backlog/TASKS`), `roadmap` (`ROADMAP`) or
`all` (the area folder); a part word alone (`:TasksVault clipboard features`) takes the area from the buffer. A word
that is both a part and the name of an area (`all` and the area `ALL`, in any case) means the area; the part is then the
second word (`:TasksVault clipboard ALL all`). Part words are never completed to an area by prefix.

| Verb | What it does |
| --- | --- |
| `open` | `backlog`: `Backlog/README.md` in a buffer; `roadmap`: its `ROADMAP.md`, else `TASKS.md`; `features`, `tasks` and `all` are folders and open in the explorer |
| `clipboard` | the path of the folder into the `+` register; `--rel` relative to the current file, `--file` the index file instead of the folder (`backlog` and `roadmap` have one) |
| `paste` | the same path at the cursor (a buffer that cannot take text gets the `+` register and a note) |
| `link` | `[<area> <part>](<relative path>)` at the cursor, relative to the current file |
| `find` / `grep` | a pickers.nvim picker rooted at the folder: file names / content (without pickers.nvim: the explorer) |
| `tree` | the folder in the file explorer (filetree.nvim when it is there) |
| `cdx` | a ready prompt for Claude Code that names the folder, into the `+` register (`--rel`, `--file` as above) |
| `new feature\|task <title...> [--area=]` | a dated note `Backlog/FEATURES\|TASKS/<date>_<slug>.md`, its README row, opened |
| `create [<dir>] [<area>...] [--force] [--yes]` | a vault folder with the named areas and a marker file `tasks-vault.json`; lists what happens first (see below) |
| `switch <name>` | work on another named vault in this session (see below) |
| `status` (and the bare `:TasksVault`) | the vault in use (with its name), its areas and the area of this buffer |

**Several vaults.** `setup({ vaults = { main = "~/tasks-vault", tricentis = "~/tricentis-vault" }, vault = "main" })` names
them; `vault` may be a name (a path stays valid and names nothing; without `vault` the first name, sorted, is active).
`:TasksVault switch <name>` completes the names and changes the vault of the running session: every command after it
(`:Tasks`, the dashboard opened next, `:checkhealth tasks_nvim`) works on the new one. A dashboard that is open is
closed and opened again on the new vault (with the filter remembered for that vault, and its area when the new vault has
one of that name); with several names configured its title starts with `[<name>]`. An unknown name, or a folder that is gone, is refused and the active
vault stays. Areas of the same name in two vaults are separate (`lib.nvim` in each). `:TasksVault status` and
`:checkhealth` show which vault is active. `vault_rules = { { match = "~/work", vault = "work" } }` picks the vault by
the working directory when `setup()` runs: the first rule whose folder is the cwd or lies above it wins over `vault`; a
rule for a name `vaults` does not have is skipped, and without a match `vault` decides. `switch` changes it later.

**No vault.** The command exists even then, because `create` is what makes one. Every other verb answers with the same
single notice (what to do: `:TasksVault create <dir>`, or `vault` in `setup()`, or `$TASKS_VAULT`) and does nothing
else, a stray word on the command line included. `vim.g.tasks_nvim_no_vault_command = true` keeps `:TasksVault` out,
`vim.g.tasks_nvim_no_command = true` keeps `:Tasks` out (a host that mounts its own verb); the two are independent.

**`create`.** Goes in four steps and says so *before* it does anything (a confirmation; `--yes` skips it):

1. the folder, name and location (asked for when missing, default `~/tasks-vault`);
2. the areas, every word after the folder (`ROADMAP/tasks`, `Backlog/FEATURES`, `Backlog/TASKS`; what exists stays), and a
   `README.md` when the folder has none;
3. the vault is used for **this session** at once;
4. **your step, required**: write `vault = "<dir>"` into the setup of tasks.nvim (or set `$TASKS_VAULT`). Without it nvim
   does not find the vault again after a restart.

Step 4 is shown in the question and again, as a warning, after the vault was made; the line to write is then in the
`+` register. A folder or an area name that is refused (a drive root, a file, `../x`) is reported before the question. A vault that is in use is not replaced unless the question says so (at the editor it names the vault in use and asks, "No" first) or `--force` (with `--yes`, or with no one to ask, only `--force` replaces it); naming the folder in use again (`:TasksVault create <that folder> <area>`) adds an area to it without `--force` and switches nothing. When one of several areas cannot be made, the error names the folders made before it (they stay). The folder is a plain folder: making it a git
repository is a decision of the user, not of the command.
