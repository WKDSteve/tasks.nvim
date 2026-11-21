# `tasks_nvim` -- the task engine

Open work in a task vault is one Markdown file per task
(`<area>/ROADMAP/tasks/<slug>.md`, flat-YAML frontmatter; or a *folder task*
`<slug>/<slug>.md` that can hold assets), with a generated
overview per area (`<area>/ROADMAP/TASKS.md`). This namespace reads, ranks,
indexes, creates, changes, finishes and checks those files.

It is **pure Lua with no UI and no notifications**: functions return data or
`nil, err`, and the callers decide how loud to be. The editor commands and the
headless CLI are front ends over it.

**Why `lua/tasks_nvim/`.** `tasks` is a generic word, so a plugin shipping
`lua/tasks/` could shadow (or be shadowed by) another one; the `_nvim` suffix is the
fleet's convention for exactly that case.

**Setup.** There is no built-in vault path. Call `require("tasks_nvim").setup({ vault = "<dir>",
extra_areas = { ... } })` or set `$TASKS_VAULT` (and, for the headless CLI, `$TASKS_EXTRA_AREAS`,
comma separated). `extra_areas` names folders that are areas although they hold neither
`ROADMAP/` nor `Backlog/`.

```
lua/tasks_nvim/
├── init.lua      lazy aggregator (tasks_nvim.vault, ...) and `setup`
├── fsio.lua      byte-exact file primitives (atomic write, O_EXCL create, CRLF helpers)
├── vault.lua     vault root, areas, paths, id/slug validation
├── vault_marker.lua  the optional marker file `tasks-vault.json` (read strictly, written once)
├── model.lua     task record, enums, ranking, filters (parsed files cached by mtime + size)
├── filter_opts.lua  `--status=a,b` style options -> `Tasks.Filter` (shared by CLI, commands, dashboard)
├── scan.lua      collect task files (open and Backlog)
├── index.lua     render/write ROADMAP/TASKS.md, global export text
├── mutate.lua    template, new, set, done (plan / execute / rollback), folderize, attach
├── done_flow.lua the one entry for finishing a task (`mutate.done` + the follow-up chain, empty so far)
├── steps.lua     the optional `## Plan` section of a task: progress, tick_all, acceptance hint (pure)
├── questions.lua the optional `## Offene Fragen` section: questions, options, the recommendation, `answer` (pure)
├── plans.lua     plan files under ROADMAP/plans (parse, scan, new, close)
├── plan.lua      readiness, scopes, stages, leverage, effective prio, critical path, cycles (pure)
├── plan_scope.lua  reads the vault for the plan (open tasks, finished ids, the scope asked for)
├── plan_view.lua   a plan as Markdown / tsv / ids, the next-task texts
├── estimate.lua  sums of effort and value that name what is missing (pure)
├── next_pick.lua the best ready task, the reason, the honest empty answers (pure)
├── batch.lua     several `set` / `done` steps with one index write per area; `release` of a `waits_for` key
├── waits.lua     what the parked tasks wait for: counts per `waits_for` key, the texts, the release steps (pure)
├── soft.lua      the one probe for soft dependencies (mdview, snacks, cascade, ...)
├── form.lua      the Markdown form of `task new` (template, parse, validate, tick rules)
├── check.lua     rule checker
├── frecency.lua  visit score behind `--sort=frecency` (pure scoring + a small state file)
├── staleness.lua `--stale=refs`: referenced files changed since `updated`
├── ci.lua        CI gate: check + index --check + md_lint
├── cli.lua       command-line front end
└── @types/       LuaLS types
scripts/tasks.lua   headless entry (nvim --headless -u NONE -l)
scripts/tasks-ci.lua  same as `tasks.lua ci`, the one entry point for a pipeline
scripts/tasks-html.lua  one-file HTML overview: a consumer of `list`, `plan --format=tsv` and `next`
TESTS/              specs (run with scripts/test.sh, i.e. testing.nvim)
```

## Modules

| Module | What it does | Key functions |
|---|---|---|
| `tasks_nvim.vault` | Resolves the vault root (`opts.root`, `set_root`, `configure`/`setup`, then `$TASKS_VAULT`; no default path). An *area* is a folder holding `ROADMAP/` or `Backlog/`, plus the configured `extra_areas`; `_`-prefixed folders, `TEMPLATES` and `TOOLS` are skipped. Builds every path; whitelists area names (no trailing dot: Windows drops it), slugs and ids before they become path segments; `is_reserved_name` knows the Windows device names. An area must be spelled exactly like its folder (`has_area`, `dir_listed`; `scan.find` too): on Windows `LIB.NVIM` or `lib.nvim.` would otherwise reach the folder `lib.nvim` under a different id. | `root`, `areas`, `has_area`, `dir_listed`, `tasks_dir`, `index_path`, `backlog_dir`, `parse_id`, `valid_slug`, `is_reserved_name` |
| `tasks_nvim.vault_marker` | The optional marker file `tasks-vault.json` in the vault root (see [The marker file](#the-marker-file-tasks-vaultjson)): `read(root)` (one read per read scope), `validate(text)` (pure), `status(root)`, `render`, `write` (never over a file that is there). | `read`, `validate`, `status`, `render`, `write`, `FILE`, `KEYS`, `LAYOUT_VERSION` |
| `tasks_nvim.area_groups` | Area groups: a filter name that stands for several areas. Read from `<vault>/area-groups.json` (`{ "version": 1, "groups": { "<name>": { "include": [...], "exclude": [...], "desc": "..." } } }`; `include` / `exclude` hold exact area names or `*`/`?` globs, matched by lib.nvim's glob matcher) plus `setup({ area_groups })` (wins by name, Neovim only). A group's members are the vault's areas that match `include` and no `exclude`, so a new area joins by its name. An area of the same name wins (`shadowed`); groups do not nest; an area may be in several; `all` is reserved (the keyword for every area). A bare marker key (`<!-- tasks:plan nvim -->`) stays an area or a plan slug: a block reaches a group by `area=`, which `plan <group> --write` records. `vault.area_scope(root, name)` is the one question every filter asks (`scan.open_tasks`, `plan_scope.load`, `next_pick`, the contract's `list` / `order` / `next` / `finished`, `list --done`, `plans`, the dashboard); writes keep `has_area`, and `mutate.new` refuses a group with its members named. A broken file is no groups plus a note (`check`: `area-groups-invalid`). | `load`, `decode`, `normalize`, `all`, `get`, `names`, `members`, `resolve`, `not_a_target_message` |
| `tasks_nvim.model` | `parse_text` / `from_file` turn a file into a `Tasks.Task`. `categories(task)` is the effective category set (below). A broken file is still returned, with `errors` / `error_codes` and `valid = false`: one bad file never hides the rest. `summary` is the frontmatter `summary`, else the first body paragraph. Sorting is status rank (`doing`, `decision`, `blocked`, `open`, `parked`), then prio, then area, then slug; `sort(tasks, order)` also knows `prio-effort` and `severity` (below). | `parse_text`, `from_file`, `sort`, `compare`, `parse_sort`, `effort_days`, `filter`, `is_date`, `days_between`, `reset_parse_cache` |
| `tasks_nvim.wikilinks` | Obsidian wikilinks in `blocked_by`, `after` and `plan`. `read` says what one value names: `plain` (an id, checked by the caller), `id` (`[[<area>/<slug>]]` with or without `\|alias` / `#heading`, or the vault path of a task, folder task, plan or finished file, `.md` optional), `slug` (a bare `[[<slug>]]`, date prefix dropped) or `bad`. `parse_text` turns the id forms into ids at once and leaves the bare slugs in `task.wikilinks`; `scan` settles them with `resolve` against `build_index` (every task and plan id by slug, from the folder listings alone, once per call or read scope and only when a task has such a link): one id replaces the link, none or several leave it as written in `blocked_by` / `after` (an unresolved `plan` leaves the task without a plan) and name it in `task.link_problems` (`check`: `wikilink-dangling`, `wikilink-ambiguous` with the candidates; the task waits like on a dangling id). The writer: `mode` (`opts.links`, a `links` that `setup()` set (`config.given`), `$TASKS_LINKS`), `render` (`plain`: the id; `wikilink`: the file name when the slug is unique (`[[<slug>]]`, a finished task `[[YYYY-MM-DD_<slug>]]`), else `[[<vault path>\|<id>]]`), `forms` (an id the file already names keeps its form there, one typed as a wikilink keeps that, the rest is rendered). `split` cuts a typed list (`[[a]], b/c`, the file's `["[[a]]", ...]`) with `[[...]]` and quotes as atoms. `slug_referrers` names the tasks whose raw fields hold a bare `[[slug]]`; `mutate.new` uses it to warn when a new slug makes those links ambiguous (`ambiguity_message`). | `read`, `split`, `build_index`, `resolver`, `resolve`, `typed_id`, `mode`, `render`, `forms`, `slug_referrers`, `ambiguity_message` |
| `tasks_nvim.mdlinks` | The relative Markdown links of a file (`[]()`, `![]()`, `[id]: target`), outside the frontmatter, fenced code blocks and inline code; `http(s):`, `mailto:`, any other scheme, `#anchor`, absolute paths and a machine's paths (`$REPOS_DIR/...`, `~/...`) are not relative. `shift` gives every relative link outside `assets/` one `../` more (what `folderize` and `attach` write when a file moves into its folder form), `missing` lists the links whose file is not there (`check`). | `scan`, `is_relative`, `is_asset`, `shift`, `resolve`, `missing` |
| `tasks_nvim.relink` | Relative links that follow a moved file: `rewrite(text, old_dir, new_dir, moves)` rewrites a link only when it would name another file after the moves (the shortest way, `#anchor` and a leading `./` kept), `follow(root, moves)` does it for the files below `ROADMAP/` and `MEETINGS/` of every area and the moved files (`done`, `reopen`, `moves.move`, `folderize`, `attach`), `repair(root, areas, { dry_run })` mends dead links by slug (`tasks relink`). | `rewrite`, `follow`, `repair`, `relpath`, `files` |
| `tasks_nvim.filter_opts` | Turns the textual options of a front end (`status=a,b`, `prio=<=2`, `effort=S,M`, `stale=refs`, ...) into a `Tasks.Filter`. Unknown words and empty values are errors, never silently ignored. | `parse`, `split_commas` |
| `tasks_nvim.plan` | The plan of a set of open tasks, pure: `blocked_by` (hard), `after` (soft), the stage order of plan files. `classify` / `ready` are THE definition of "can be started" (open / doing / decision with no open blocker; a finished blocker is met; an unknown blocker is not; a parked blocker or a cycle is `stuck`): `list --ready`, the dashboard, `next` and the plan all ask it. `scope_for` is a task plus everything before it across areas. `build` returns stages (earliest possible, Kahn; soft edges and plan stages move a task later, never make it wait; a soft edge that would close a cycle is dropped with a warning), the order inside a stage (status, effective prio, `order`, leverage, effort, id), `same-file` marks (tasks of one stage naming the same file in `refs`), leverage, the effective prio with the inversion, the critical path (unknown effort counts as one day and is counted), cycles (iterative Tarjan: a long chain cannot overflow the stack; members named, left out of the stages) and warnings. | `index`, `classify`, `ready`, `scope_for`, `build` |
| `tasks_nvim.edges` | What a change of `blocked_by`, `after`, `plan` or `phase` would break, asked BEFORE the write (`validate(id, proposal, { root })` -> a list of problems, empty when the change is clean). The rules and codes are `check`'s: `blocked-by-self` / `after-self`, `blocked-by-dangling` / `after-dangling` (a finished blocker is met and allowed), `blocked-by-cycle` (judged on the whole graph with the change applied, stage gates of the plan files included; a soft `after` that closes a circle is not an error), `plan-unknown`, `plan-phase` (the plan lists stages and the phase is not one of them; `check` warns, a change that has not happened yet is refused). Pure over one pass of the vault; nothing is written. | `validate` |
| `tasks_nvim.moves` | Moving a task to another area, stage 1: `preview(id, to_area, { root })` answers whether the move could be made (the area exists, the slug is free there among open tasks, finished tasks and plans: otherwise `conflicts` with `slug-taken`) and what would dangle (`references`: the `blocked_by`, `after` and `refs` of other tasks, the `target` of a plan file, a configured document that names the id), with notes such as a plan that does not list the new area. Nothing is written; rewriting the references with a rollback is stage 2, until then the move itself is refused. | `preview` |
| `tasks_nvim.steps` | The optional `## Plan` section of a task (`- [ ] 1. step -- Acceptance 1`): `parse` reads progress ("2/4") and the step texts, `tick_all` ticks the open steps byte-exactly (line endings kept; a step marked `(dropped)` / `(entfaellt)` is struck from the count and never ticked; code fences and other sections are not the plan), `uncovered_acceptance` names acceptance points no step refers to (a hint in `check`, never an error). A task without the section is complete: nothing is said about it. | `parse`, `tick_all`, `uncovered_acceptance`, `template_section` |
| `tasks_nvim.plans` | Plan files, `<area>/ROADMAP/plans/<slug>.md` (or the folder form `<slug>/<slug>.md`, whose other files are assets: `assets` lists them): frontmatter `title`, `status` (planning / doing / parked / done), `areas`, `target`, `phase_order`, `gate` (`hard`), `links` (http/https), dates; no task list. `parse` / `from_file` always return a plan (a broken one carries errors), `area` / `all` / `find` read them, `members` picks the tasks that name one, `new` creates one (never overwrites), `close` finishes one like a task (moved to `Backlog/FEATURES/`, a README row, snapshot and rollback), `summary` says what a finished plan amounted to. | `parse`, `area`, `all`, `find`, `members`, `new`, `close`, `summary` |
| `tasks_nvim.meetings` | Meeting files, `<area>/MEETINGS/<slug>.md` (or the folder form `<slug>/<slug>.md`), see [Meetings](#meetings-meetings): a meeting is no task and names its tasks (`tasks:`); `by_task` derives the meetings of a task. `parse` / `from_file` always return a meeting (a broken one carries errors; a parse cache by mtime and size), `area` / `all` / `find` read them, `online_service` tells the service of an address, `parse_duration`, `parse_notify`, `is_tz` read the fields; a series (`repeat`) is computed into its occurrences (`occurrence_days`, `expand`), `find_any` also reads an occurrence without a file. | `parse`, `from_file`, `area`, `all`, `find`, `find_any`, `by_task`, `less`, `online_service`, `occurrence_days`, `occurrence`, `expand` |
| `tasks_nvim.meeting_write` | Writing meetings under the file lock, on the version read: `new`, `set`, `close`, `capture` (one line of the minutes), `attend`, `followups` (tasks of the follow-ups), `board_save` (a whiteboard, replaced only on the version read); `renames_for_move` and `tick_done` for `move_area` and `done`; pure body helpers (`capture_body`, `attend_body`, `tick_item`, `add_items`, `append_to_section`, `set_section`). | `new`, `set`, `close`, `capture`, `attend`, `followups`, `board_save`, `edit` |
| `tasks_nvim.meeting_quick` | The quick capture of a meeting: one line (day, time, duration, all-day, address, `@place`, `#task`, `!notify`, the rest the title) read into a proposal of the fields of `meeting_new`, with what it assumed and the words it could not read. Pure. | `parse` |
| `tasks_nvim.lernbaum` | The learning tree of `## Lernpunkte`, see [Learning paths](#learning-paths-roadmappaths): nodes with marks, keys, reasons, arrows, notes and images; the parent rule, progress counted apart, the problems of one file; `render` gives the text back byte for byte. Pure. | `parse`, `render`, `set_state`, `set_xp`, `set_task_xp`, `suggest_xp`, `to_xp`, `node`, `progress_text`, `promoted_ids` |
| `tasks_nvim.lernlevel` | The levels of a learning path (`## Level`), see [XP, levels and rewards](#xp-levels-and-rewards-optional): thresholds in XP or percent, badges, rewards; the level reached, the next, the rewards not granted; `set_reward` writes back byte for byte. Pure. | `parse`, `evaluate`, `set_reward` |
| `tasks_nvim.paths` | Learning paths, `<area>/ROADMAP/paths/<slug>.md` (read by `plans` with `kind = "path"`): list, make, change, finish, change one learning point on disk, give the promoted points the XP of their tasks and mark a reward granted. | `from_file`, `area`, `all`, `find`, `new`, `set`, `close`, `point`, `set_reward`, `task_xp`, `with_xp` |
| `tasks_nvim.milestones` | Milestones, `<area>/ROADMAP/milestones/<slug>.md` (or the folder form), see [Milestones](#milestones-roadmapmilestones): a dated bundle of ids (`includes`) of tasks, plans, projects, paths and meetings. `parse` / `from_file` always return a milestone (a broken one carries errors), `area` / `all` / `find` read them, `member` resolves an id (kind, done or open), `progress` / `units` count, `overlaps` names a member that is in it twice, `settle` reaches and opens them again after a write, `new` / `set` write them under the file lock. | `parse`, `from_file`, `area`, `all`, `find`, `member`, `complete`, `progress`, `overlaps`, `settle`, `new`, `set` |
| `tasks_nvim.plan_scope` | The impure edge of the plan: one scan of the open tasks, finished ids looked up in the Backlogs when a blocker is not open, the scope cut like the commands do (area, `--for`, filters); `filter_readiness` serves `list --ready|--waiting`. `shared` is ONE pass over the vault (open tasks, finished ids, plan files, which file a ref means) that `load`, `filter_readiness` and the dashboard reuse. The marker blocks of documents: `refresh_document` (every block of a file, after a finish), `write_block` (`plan --write`), `marker_attrs`, `resolve_block`. | `shared`, `load`, `index`, `filter_readiness`, `refresh_document`, `write_block`, `marker_attrs`, `resolve_block` |
| `tasks_nvim.plan_view` | A plan as Markdown (ready now, decisions by leverage, stages, critical path, warnings, the estimate line), `tsv` or `ids`; the `next` lines and the dialog text; the marker blocks of a document (`parse_blocks`, `replace_blocks`: fence-aware, per-line endings kept, the start marker carries attributes; `start_line`, `parse_start`). | `markdown`, `tsv`, `ids`, `next_lines`, `next_message`, `empty_text`, `parse_blocks`, `replace_blocks`, `replace_block`, `start_line`, `parse_start` |
| `tasks_nvim.estimate` | Sums over tasks: effort days with how many tasks they are made of, a range (every size at its low and its high end), value, roi over the tasks with both numbers, quick wins, the split by actor, progress from finished tasks. A task without an estimate is missing, never 0. | `rollup`, `describe`, `fmt_days` |
| `tasks_nvim.lists` | Named lists: `normalize(name, def)` checks a definition with `filter_opts.parse` / `model.parse_sort` and names the list in every complaint; `resolve` gives the `Tasks.Filter`, the sort order and the area; `all` / `get` merge the sources (built in, saved, `setup({ lists })`, the later one wins by name, shadowing and rejected lists come back as notes); `save` / `delete` / `rename` change only the saved file (`stdpath("state")/tasks/lists.json`, atomic, never written over an unreadable or corrupt file); `from_filter` turns the dashboard's live filter into a definition (the quick-win bounds become `quick_win = true`); `words` prints a list as option words. | `normalize`, `resolve`, `all`, `get`, `save`, `delete`, `rename`, `from_filter`, `words`, `path` |
| `tasks_nvim.quick_wins` | The quick-win report, pure: `build` groups the quick wins (best roi first), the small tasks without a value and the valuable tasks without an effort; `tsv`, `ids` and `markdown` (every cell through `fsio.md_cell`, an optional file column, `by_actor`) render it; `write` is the only function that touches the disk (a file this command did not generate is never replaced). The rule itself is `estimate.is_quick_win`. | `build`, `tsv`, `ids`, `markdown`, `write` |
| `tasks_nvim.next_pick` | What to start next, pure: candidates are what `plan` calls ready; freed by the finished task, then area, then vault; status, effective prio, roi, effort, id. Tasks written `cdx` are listed apart unless that queue is asked for. An empty answer says which kind (`all_done` only when nothing is open at all, `nothing_startable` with counts, `only_cdx`). | `pick`, `pick_from_vault` |
| `tasks_nvim.done_flow` | The one entry for finishing a task: `run(id, opts)` calls `mutate.done` and returns `{ done, steps_ticked, freed, plans_closed, docs_refreshed, notes, next }`. The `:Tasks done` command, the dashboard (through `batch.done_many`) and the CLI call only this. `preview(id, opts)` is the same finish worked out and not written (`mutate.done_preview`: target path, README row, the steps it would tick, the plan it would close, the tasks it would free), with the `etag` of the file it read and a `confirm` token for that version (`mutate.confirm_token` / `confirm_etag`: `done-`, 16 hex digits of the etag, six digits binding the id; stateless, a host adds its own authorisation). `run` takes `if_match`: a task file that is not that version is a `conflict` and nothing moves. The chain names the tasks it freed and picks the next task (`next_pick`); plan steps, plan files and generated blocks land behind the same seam. A failure after the finish never undoes it and goes to `notes`; an already finished task runs no chain; `batch.done_many` picks once for a whole stack and checks each plan once (`close_plans`). `marker_docs` is the list of documents a finish refreshes (config plus `$TASKS_MARKER_DOCS`). | `run`, `preview`, `close_plans`, `marker_docs`, `refresh_marker_docs` |
| `tasks_nvim.batch` | `set_many` applies steps `{ id, patch, expect = { key, value } }` (a step whose task changed since it was read is refused) and `done_many` finishes several tasks; both write each area index once. `plan_cycle` plans advancing `status` / `prio` of a selection (each task from its own value; the steps carry `expect`), `model.cycle_status` / `cycle_prio` are the cycles: the dashboard only presses the keys. `reorder(id, { after, before, group, if_match }, opts)` moves a task inside its group (same stage, same `status|effective prio`, `plan.group_key`): it gets an `order` between its neighbours', tasks without an `order` are numbered only where the spot needs it (those before it), two values closer than `MIN_ORDER_GAP` renumber the numbered tasks 1, 2, 3, ...; a neighbour of another group, a group the caller did not see or neighbours that are no longer adjacent is a `conflict`, a move that would write more than `MAX_REORDER_WRITES` files is refused, every write is a `set` with `expect` on `order` (not all-or-nothing: what was written stays and the answer says how far it got), the answer carries the `inverse` that puts it back in its place and `restore` (a `set` of `order` for every file written) that gives every file its old value back. `plan_reorder` is the pure placement. | `set_many`, `done_many`, `plan_cycle`, `reorder`, `plan_reorder` |
| `tasks_nvim.scan` | `lib.nvim.fs.collect_recursive` (or the TTL cache `scan_cached` with `ttl_seconds`) over `ROADMAP/tasks/` and `Backlog/`. A folder task's `<slug>/<slug>.md` is a task (`task.folder`), the other files in its folder are assets and ignored; any other nested file is returned, flagged. Backlog files count as tasks only with frontmatter and a `status`. A folder whose real path is outside the vault (a `ROADMAP` or `tasks` that is a link or a junction) is not read and is reported as a walk error (`vault.leaves`). Every function settles the bare `[[slug]]` wikilinks of what it returns (`wikilinks.resolve`; `opts.link_resolver` shares one index over several calls, `all` and `check` do). | `area`, `all`, `backlog`, `find`, `find_done`, `backlog_slugs` |
| `tasks_nvim.history` | The series of the overview figures (see [The series of the figures](#the-series-of-the-figures-_telemetryhistory)): `figures` counts a view by area (open, by status, by readiness, with effort and value, their sums), `record` writes the rows of today for the areas that changed (`changes` decides, `write_rows` replaces a row of the same day and area and keeps every other line), `read` returns one row per day and area (the later `at` wins) and names the lines it skipped, `levels` sums the last row of every area per day of a window. `parse_row` is the one judge of a line. | `figures`, `record`, `read`, `levels`, `changes`, `write_rows`, `parse_row`, `exists` |
| `tasks_nvim.history_backfill` | Fills the series for past days from the repository of the vault: `days` lists the days of `HEAD` that have a commit with their last commit, `run` lays the tree of each day without a row into a temporary folder (own index file, the repository untouched), counts it and writes rows marked `src: git`. Needs git; the web variant never calls it. | `days`, `run` |
| `tasks_nvim.index` | `render` is pure and deterministic: the same tasks give the same bytes, whatever order they are found in. `write_area` writes only when the content differs (a CRLF checkout counts as equal and keeps its line endings), removes the file when no task is open, and with `check = true` only reports `stale` (`missing` / `outdated` / `orphan`). `render_global` returns the all-areas overview as text; nothing writes `ALL/TASKS.md` (decision E2: it is never committed). | `render`, `write_area`, `write_all`, `render_global` |
| `tasks_nvim.mutate` | `new` creates the file with `O_CREAT\|O_EXCL` (a taken slug gets `-2`, `-3`, ...; a slug used in `Backlog/` or as a folder counts as taken; `folder = true` makes a folder task). `set` validates the patch, changes only the named keys through `lib.nvim.markdown.frontmatter` and bumps `updated` only when something changed. `blocked_by`, `after` and `plan` take ids and wikilinks (resolved to ids, a bare slug against the vault); they are written through `wikilinks.forms`: what the file holds keeps its form, a typed wikilink stays as typed, a new id follows `links` (`opts.links`, `setup`, `$TASKS_LINKS`). `new` writes `after` and `plan` the same way. `done` is rule R6 (below). `folderize` and `attach` turn a task into a folder task and copy assets into it. All regenerate the area index. | `template`, `new`, `set`, `done`, `folderize`, `attach`, `slugify`, `readme_add_row`, `SETTABLE` |
| `tasks_nvim.form` | The form behind `task new` without arguments, with no UI: `template` builds the Markdown text (`Area:` / `Title:` / `Summary:` / `Tags:` / `Refs:` lines, the free-text sections Kontext / Akzeptanz / Notizen and one `- [ ]` / `- [x]` bullet list per choice field, the value sets read from `tasks.model`), `parse` reads what the user left in it, `validate` checks it (area known, title present, one tick on a single-choice list) and returns `tasks.mutate.new` options, `toggle` flips one bullet and keeps a single-choice list at one tick (`category` takes several). It creates nothing: the editor layer passes the values to `mutate.new`, the same write path as the CLI. | `fields`, `template`, `parse`, `validate`, `toggle`, `normalize`, `error_lines`, `strip_errors` |
| `tasks_nvim.check` | Collects findings over one area or the vault (table below). | `run`, `format` |
| `tasks_nvim.staleness` | `--stale=refs`: which open tasks carry a `refs:` path that changed after their `updated` (below). `compute(tasks, opts)` returns the report, `model.filter` calls it for `Tasks.Filter.stale_refs`, `classify` reads one ref; `compute_async(tasks, opts, cb)` is the same check without blocking (the editor's path). | `compute`, `compute_async`, `classify`, `describe`, `git_dates`, `git_dates_async` |
| `tasks_nvim.frecency` | The score behind `--sort=frecency` (below): `bump` / `decayed` / `scores` / `prune` are pure and take the time as an argument; `load` / `save` / `record` / `load_scores` touch `stdpath("state")/tasks/frecency.json` (or `$TASKS_FRECENCY_FILE`, `set_path`). Half-life 14 days, at most 500 entries, a corrupt file starts empty. | `record`, `load_scores`, `bump`, `scores` |
| `tasks_nvim.ci` | The vault gate for pipelines: `check` (errors fail; `strict` fails on warnings too), `index --check`, and the vault's `md_lint.lua` over every generated `ROADMAP/TASKS.md`. Returns exit code, step names and printed lines. | `run` |
| `tasks_nvim.cli` | Parses a command line, calls the engine, prints tab-separated lines, returns an exit code, never raises. | `run` |
| `tasks_nvim.contract` | The read side of the machine contract `tasks-export/1` ([CONTRACT.md](CONTRACT.md)): one Lua table per document (`hello`, `snapshot`, `list`, `task`, `next`, `areas`, `error_doc`) built from one scan and one plan (`view`), no path of this machine in it, a task without an estimate has no number. `seal` adds `rev` and `digest`; `encode` writes the canonical bytes and turns a document over 8 MiB into `payload_too_large`. Only reads. | `view`, `hello`, `snapshot`, `list`, `task`, `next`, `areas`, `error_doc`, `encode`, `seal` |
| `tasks_nvim.api` | The one door for everything outside the engine: `call(method, request, opts)` answers with the text of one document (or a `tasks.error`) and **never throws**. Checks the request strictly (an unknown field or parameter is `invalid_argument`, a higher `schema` is `unsupported_schema`, at most 256 KiB) and maps the engine's error strings to the stable codes. | `call`, `methods`, `METHODS` |
| `tasks_nvim.ops` | The write door of the machine contract, `tasks-ops/1` ([CONTRACT.md](CONTRACT.md#writing-tasks-ops1)): `run(params, opts)` answers a request `{ client_op_id?, dry_run?, ops }` with one `tasks.result`. The shape of the whole request is checked first (an unknown operation or field, a wrong type, more than 100 operations: nothing runs); then each operation runs on its own (`set`, `new`, `reorder`, `done`, `move_area`) and a failure does not stop the next. `set` is a compare-and-set (`if_match`, `expect`, under the lock), relations are judged by `edges` first, limits and a strict `refs` check for new entries are kept on writing, errors carry ids and never a path, the index of an area is written once at the end, every change brings its `inverse`. `done` needs the `confirm` token of `done_preview`. | `run`, `OPS` |
| `lib.nvim.contract.*`, `lib.nvim.json.canonical` | The mechanics the contracts of tasks.nvim and rules.nvim share, moved to lib.nvim (tasks.nvim@6bc8d99) and used from there: `contract.doc` (head, seal, canonical bytes, 8 MiB limit, no path of this machine; `tasks_nvim.contract.doc` is the instance), `contract.api` (the dispatcher behind `tasks_nvim.api`), `contract.ops` (shape check, loop and `tasks.result` behind `tasks_nvim.ops`), `contract.host` (the line protocol behind `tasks_nvim.host`), `contract.errors` (`classify`, `fail`, `scrub`; the engine's own message patterns are `contract.ERROR_PATTERNS`), `json.canonical` (`encode`, `object`, `array`, `memo`), and `fs.etag`, `fs.with_lock`, `fs.create_exclusive` behind `tasks_nvim.fsio`. | |
| `tasks_nvim.cli_contract` | The command-line side of the contract: `call`, `show`, `plans`, `areas`, the JSON forms of `list` and `next`, `list --done`, `--capabilities`. Maps words to a request and the answer to an exit code. | `register`, `areas`, `list_json`, `next_json`, `list_done`, `capabilities` |

## Front ends

- **Editor:** at the moment the editor commands (`tasks`, `task`, `open`, the dashboard, the form, the
  browser preview through the soft dependency mdview.nvim) still live in the author's Neovim config; they move
  into this plugin as `:Tasks <verb>` in the next stage. They add only what an editor needs on top of the
  engine: composer routes and completion, the `--to=` delivery, a form for a missing title, a confirmation
  before `done`, opening files and re-pointing buffers, a picker over one area folder. The filter words
  (`--status=`, `--prio=<=2`, ...) are parsed by `filter_opts.parse`, shared with the CLI, and
  the keys `task set` accepts are `mutate.SETTABLE`.
- **Headless:** `scripts/tasks.lua` (below).

### Categories

`category: [security, docs]` (optional, flat list) names the concern a task serves:
`bug`, `security`, `performance`, `docs`, `ruleset`, `ux`, `bindings`, `refactor`, `tests`, `ci`, `learning`
(`model.CATEGORIES`, the one list the `:Tasks new` form, `new --category`, `set category=`,
`check`, `--help` and the `hello` enums read; `ruleset` = the task
brings code in line with a rule set (for example the ones `rules.nvim` loads), optional free
field `rules: [LLS-45]` names the rule ids; `ux` = something the user sees or does, such as a
new user-facing feature; `bindings` = keymaps, commands, shortcuts; `refactor`, `tests`, `ci` =
internal work on the code, the test suite, the build pipeline; `learning` = work done to learn and get better,
not out of need, such as a protocol or a terminal, and the learning in learning paths; its scaffold lines: sources
worked through, result written and linked, self-check answered without notes, open questions noted). An unknown value is `unknown-category`. The
*effective* categories (`model.categories`, what `--category=` filters on) are the written
list, plus `bug` for every `kind: bug`, plus every tag spelled like a category -- so tasks
written before the field existed are filterable without touching them. Categories narrow a
list, they do not reorder it (the sort stays status, prio, area, slug).

### Effort filter and sort orders

`effort` is `XS S M L XL` or days (`0.5d`, `3d`). `--effort=S,M` keeps the tasks whose written
effort is one of the words (size words are case-insensitive on the command line);
`--effort=<=M` keeps "this or smaller": sizes and days sit on one scale (`XS` 0.25d, `S` 0.5d,
`M` 1d, `L` 3d, `XL` 5d -- only used for ordering and `<=`, not a promise), and a task
without effort never matches. `list --sort=<order>` (`model.parse_sort`, `model.sort(tasks,
order)`) picks the order:

| `--sort=` | Order |
|---|---|
| `default` (no flag) | status rank, prio, area, slug -- what the index uses; unchanged |
| `prio-effort` | status rank, prio, **effort ascending**, area, slug: important and small first; a task without (valid) effort comes last of its prio |
| `severity` | **severity** (`critical`, `high`, `medium`, `low`, none last), then the default order |
| `roi` | **value per effort**, highest first (`model.roi`); tasks without a figure after the ones with one, then the default order |
| `created-desc`, `created-asc`, `updated-desc`, `updated-asc` | that date, either way; a task without a valid one comes last in **both** directions, a tie is the default order |
| `remind` | the next reminder first, a task without one last, a tie is the default order |
| `title` | alphabetical regardless of case, a tie is the default order |
| `frecency` | tasks the dashboard opened or changed, **highest score first** (see below), then the default order; ignores the status rank on purpose |

`prio-effort` and `severity` keep the status rank in front on purpose, so `doing` / `decision`
tasks do not sink below parked ones. The index (`ROADMAP/TASKS.md`) always uses the default order.

#### Frecency (`frecency.lua`)

`model.sort(tasks, "frecency", { scores = <id -> number> })` ranks by a score; without `scores`
it reads the frecency file, so `list --sort=frecency` and the dashboard's `--sort=frecency`
need no wiring (a missing or corrupt file means the default order). The dashboard records a
visit when a task is opened (`<CR>`) or changed (`s` / `p`). The scoring is pure and takes the
clock as an argument (`bump`, `decayed`, `scores`, `prune`; `opts.now` in the file functions):
an entry is `{ score, last }`, a visit adds 1 after the old score decayed to now, and the
score halves every 14 days (`HALF_LIFE_DAYS`). Entries below `MIN_SCORE` (0.05, about two
months of silence after one visit) are dropped and at most `MAX_ENTRIES` (500) are kept.
The file is `stdpath("state")/tasks/frecency.json` (`$TASKS_FRECENCY_FILE` or
`frecency.set_path` override it; the specs use a temp file), written atomically, keyed by
task id. A corrupt file (also one over `MAX_FILE_BYTES`, 1 MiB; a real one is ~120 KiB at most) starts empty (the old bytes stay as `frecency.json.bad`); a file
that cannot be read is never overwritten. Why not `lib.nvim.frecency`: its fixed recency
buckets use `os.time()` directly (nothing to inject), and it has neither a half-life nor
an entry cap.

### Soft edges, order, plans and the `## Plan` section

`after: [id]` ("should come after X") is a soft edge: it never blocks, never counts as leverage or critical path, never
is an error; a soft edge that would close a cycle is dropped with a warning. `order: 2.5` is a tie-breaker inside a
stage (behind status and effective prio). `plan: <area>/<slug>` and `phase: <word>` attach a task to a plan file (above,
`tasks_nvim.plans`); a plan with a `phase_order` puts its tasks in stages -- soft by default, real blockers with
`gate: hard` (then `ready`, `next`, `list --ready` and the plan all see them: one definition). None of these fields
appears in the generated index. `check`: `bad-after`, `bad-order`, `bad-plan`, `bad-phase` (errors), `after-self`,
`after-dangling` (errors), `plan-unknown` (error), `plan-area`, `plan-phase`, `plan-target-unknown`, `plan-no-open-task` (a plan
in `doing` with no open task left: `plan-close` it, or give it tasks), `project-no-open-work` (the same for a project) (warnings),
`plan-acceptance-uncovered` (a hint for a task with steps), and a broken plan file reports its own codes.

`blocked_by`, `after` and `plan` may hold Obsidian wikilinks instead of ids (`"[[<slug>]]"`, `"[[<area>/<slug>|Alias]]"`,
the vault path of the file; `tasks_nvim.wikilinks`). Everything behind the scan sees the id: `plan`, `next`, `estimate`,
the index and the contract are the same as with plain ids. A bare slug that names no single id stays as written
in `blocked_by` / `after` (`wikilink-dangling` / `wikilink-ambiguous`) and holds the task like an unknown blocker;
such a `plan` leaves the task without a plan (like the `target` of a plan file), only `check` names it. `set` writes
an unresolved link the file already holds back as it is (a `move` rewriting another id of the list), a new one is
refused.

The chain of `done` (`done_flow`): own steps ticked with the finish, the plan closed with its last member, generated
blocks refreshed (`chain.marker_docs`), freed tasks, next task. See COMMANDS.md.

### Value, return on effort and actor

`value: 4` (optional, 1-5, `model.VALUES`) is the **expected benefit**, 5 the most. It is not `prio`: `prio` is the
order decision a human makes (urgency), `value` does not depend on time, so a task may have a high value and a low
prio for now. `roi = value / max(effort_days, 0.25)` (`model.roi`) is derived and never stored; a task without a
value or without a valid effort has **no** figure (not 0), stays visible in every view and sorts after the ones with
one. `--value=4,5` / `--value=>=4` filter, `--sort=roi` orders, the dashboard shows `v4`, the CSV gets the columns
`Value` and `ROI`. A value outside 1-5 is the error `bad-value`.

**Quick win** (`estimate.thresholds()`: the `quick_wins` config section, built-in `QUICK_WIN_VALUE` = 4 and
`QUICK_WIN_DAYS` = 0.5): `value >= min_value` and `effort <= max_effort`, both written. A task missing either number is unestimated and never counts (`estimate.rollup` lists them in `unestimated`).
`rollup().quick_wins` is the single source; front ends must not re-derive the rule.

`actor: cdx | me | pair` (optional) says who can do the task: `cdx` an AI session alone, `me` only the human
(decisions, live tests, accounts, publishing), `pair` the AI drafts and the human decides the rest. A task without
the field is "unclear", not wrong. `model.actor(task)` is the written value, else `me` for `status: decision` or the
tag `needs-user`, else `nil` (the tag `agent` is **not** read as `cdx`: it sometimes only means an agent hint). So
`--actor=me` works on an unmigrated vault; `--actor=none` lists what nobody classified. `check` warns
`actor-cdx-waits-on-me` when a task written `cdx` waits on an open task that only you can do, and `bad-actor` is the
error for an unknown word. The CLI `set <id> status=doing` on a task that is for you prints a warning (a guard rail,
never a refusal). `migrate-actor [area] [--write]` proposes `me` for the derivable tasks and leaves every other task
empty on purpose (the share of empty ones is the honest number); it is a dry run unless `--write`, and writes through
`set` (so `updated` and the index follow). Neither field appears in the generated index (the same reason as for
severity: an extra column would make every index stale); the list TSV is unchanged, the CSV export appends columns.

### Severity

`severity: high` (optional) rates a **bug or security** task: `low`, `medium`, `high`,
`critical` (`model.SEVERITIES`). "Bug or security" means `kind: bug` or the effective category
`bug` / `security` (see Categories). An unknown word is the error `unknown-severity`; a
severity on any other task is the warning `severity-without-bug-or-security`. `--severity=`
filters (a task without one never matches), `new --severity=` / `set severity=` write it, `set
severity=` removes it. The generated index (`ROADMAP/TASKS.md`) does **not** show it: its
format stays as it is (an extra column would make every index stale at once, and `check`
reports that as an error); the dashboard, the CSV export and `--sort=severity` use it. The
`list` TSV columns are unchanged as well.

### Parked with a reason (`waits_for`)

`waits_for: mac` (optional) says what a **parked** task waits for from outside: a machine, a licence, a decision of
somebody else. Exactly one key, a word of the vault's own -- lower-case letters, digits and `-`, at most 40 characters
(`model.is_waits_for`; `none` is reserved, it is what the filter calls a parked task without a reason). `parked` without
the key stays valid: set aside by choice.

| | |
|---|---|
| a value that is no key | the error `invalid-waits-for` |
| the key on a task that is not `parked` (written by hand) | the warning `waits-for-without-parked` |
| `set waits_for=<key>` on a task that is not parked | the task is parked in the same write (`new --waits-for=<key>` creates it parked) |
| the status leaves `parked` (`set`, the dashboard's cycle, `batch.set_many`, the `set` of `tasks-ops/1`, `done`, `reopen`) | the key is removed in the same write; the `inverse` of the operation names both keys, so an undo brings the reason back |
| `status=<not parked>` and `waits_for=<key>` in one patch | refused: it contradicts itself |

`--waits-for=a,b` filters (`model.filter`: only parked tasks match, `none` = parked without the key); `tasks_nvim.waits`
counts (`summary`: per key the tasks and their areas, the parked ones without a reason, those with an invalid key) and
words the numbers (`parked_text`: "30 parked (25 waiting for mac)", used by `next` and the plan header);
`batch.release(key)` sets every parked task of a key to `open` through `set_many`, each step guarded by the key it was
planned from.

Where it shows: `[waits: mac]` in a dashboard line, a trailing cell `waits: mac` in the `list` TSV (a line of a task
without a reason is unchanged), the column `Waits for` appended to the CSV, `waits: mac` in the note column of the plan
and "N parked (...)" in its header -- both only when a parked task names a reason, so a generated plan block without one
does not change -- and ``(wartet auf `mac`)`` in the summary cell of `ROADMAP/TASKS.md`. **The index of a task without
`waits_for` is byte for byte what it was** (no new column, nothing reordered): introducing the field makes no index
stale. The template (`tasks template`) and the `:Tasks new` form do not carry the key.

### Taking an intent (`wkd-intent/1`)

An intent is what another app (testing.nvim, the hub) hands to tasks: "make a task of this finding", "show this task"
(`appkit/schemas/wkd-intent/1`: document, schema, one golden per action; `TESTS/intent/` holds copies). tasks takes two
actions, `tasks.new` and `tasks.show`, in mode `form`, and says so in the handshake (`hello.intents`); a sender offers only
that. The engine never writes by itself: the headless answer is what it WOULD do, `--yes` does it.

`tasks intent <file|-> [--yes] [--lang=de|en]` (and the API method `intent` with `{ intent, yes? }`):

- the intent is **untrusted input**, checked on tasks' side whatever way it came (`tasks_nvim.intent.check`, a port of
  `tools/check-wkd-intent.py`): at most 64 KiB measured before parsing, one JSON object of the schema, an offered action and
  mode, `class` `public` or `internal`, no absolute path or way out of the repository in `where.file`, `repro` and `target.id`
  (also not behind a quote or `=`), the lengths (title 120, excerpt 4096, repro 1000, file and id 300, in characters), no control
  character, a run url on `https://github.com/`. Every problem is named (`intent refused: a; b`), nothing is written.
- `tasks.new`: the finding's `area` has to be an area of the vault. The key is the ref `testing-finding:<fp>`: a task (open or
  finished) that holds it makes the answer `exists` (with `matches`), never a second task. Else `would_create`, or with `yes`
  `created`: a `bug` task tagged `testing`, refs `testing-finding:<fp>`, `<file>:<line>` and `<repo>@<sha>`, the excerpt, the
  repro command and the run url in the body, the acceptance "the finding is gone".
- `tasks.show`: `shown` (id, area, status, `open` or `done`) or `not_found`; the engine has no form to open, the editor
  does that from the answer.
- the CLI prints `would_create<TAB>area<TAB>title`, `created<TAB>id`, `exists|shown<TAB>id<TAB>status<TAB>location`.

**Refs of registered namespaces** (`rules-target:<folder>`, `testing-finding:<fp>`) may be written through the `ops` door
(`ops.REF_NAMESPACES`); any other `<ns>:` stays refused as a colon that is no line suffix. `find { refs }` (document
`tasks.find`) asks the other way: which tasks, open and finished, name these refs (id, area, status, location, never a path;
at most 50 refs).

Not built: the editor form filled in from an intent (`:Tasks new`), the other modes (`ai-draft`, `agent`), the other actions
(rules, ai), `rules_import.existing` through `find` (it matches rule ids, not refs).

### Claims

A claim reserves an open task for the time somebody works on it, so two agents (two Claude chats, an agent and the editor)
do not take the same task. `claim <id> --by=<name> [--for=4h]` writes who, since when and until when into
`<vault>/.claims/<area>/<slug>.json` (UTC, seconds; a `.gitignore` of `*` is made beside it, so a claim lives on this machine,
makes no commit noise and is no data of the vault) and sets the task to `doing`, the visible sign. The default is 4 hours, the
longest 24; `--for=90m|2h|1d`. `unclaim <id>` gives it back (a `doing` task goes to `open`, `--status=parked|decision` for
the other cases; the CLI verb is `unclaim` because `release <key>` is the verb of the parked tasks, the ops door calls it
`release`); `done` releases by itself and a task in `Backlog/` has no claim.

- **Names.** `--by` is free text (1 to 64 of letters, digits and `. _ : - @`). Without it the engine takes
  `cdx:<8 characters of $CLAUDE_CODE_SESSION_ID>` inside a Claude Code session, else `<user>@<host>`; an agent should name
  itself. The same name claiming again renews (the start stays); `--renew` insists on that and refuses a name that holds no
  claim.
- **Expiry.** A claim whose `until` has passed counts as free: `claim` takes it over (and says whose it was), every write
  is allowed, `check` warns `claim-expired`. A chat that died blocks nothing for longer than its duration. Time is UTC
  and always passed in (`opts.now`), so the specs need no waiting.
- **The guard.** A valid claim of **another** name refuses `set`, the text edits (`tick_step`, `add_steps`, `answer`,
  `append_note`, `set_body`), `done` and its preview, `attach`, `folderize`, `reorder` and `move_area` (the reference
  rewrites of a move do not ask). The answer is `conflict` and the message names the owner and the time
  (`... is claimed by chat-1 since ... until ...`). `--force --note=<why>` passes it (without a note it is refused) and, on `set`,
  `attach`, `folderize` and `done`, writes `claim of X overridden by Y: <why>` into the notes (also of a finished task). Reading (`show`, `list`, the documents) is free.
  The guard runs under the task file's lock, the one `set` and `done` hold, so reserving and changing never interleave;
  two processes that claim at once have exactly one winner.
- **`next`** and **`list --ready`** (also the ready filter of the dashboard and the contract) leave out the ready tasks of other names and says how many (`claimed: 2 task(s) left out ...`); the owner
  sees his own (`--by`), and `doing` of an unclaimed task ranks as before.
- **`check`**: `claim-expired`, `claim-orphan` (a claim file of a task that is not open: delete it) and `doing-unclaimed`
  (`doing` for seven days or more since `updated`, nobody claimed it), all warnings.
- **Not built / limits.** The store is a file per claim on one machine: a vault synced by something that is no git
  (OneDrive, Obsidian Sync) does not carry `.claims/` between machines on purpose. Not claimed: plans, areas.
  The editor has no `:Tasks claim` yet (the CLI and the ops door have). The module is `tasks_nvim.claims`; its store
  functions (`read`, `list`, `write`, `remove`) are the one place to replace for another backend (a frontmatter field).

### Routines (`repeat`)

`repeat: 8w` on a task makes it a routine: a whole number of 1 to 999 and `d` (days), `w` (weeks), `m` (months) or `y`
(years). `repeat_from: done|due` says where the next round counts from (`done`, the default: the day the round was
finished, so a late round does not pile up; `due`: the due date of the finished round, a fixed rhythm that skips rounds
that were missed). `new --repeat=8w [--repeat-from=due]`, `set <id> repeat=2w` (empty removes it and ends the routine).

`done` (the `done_flow`, so the editor, the dashboard's `D`, a batch and the CLI alike) writes the finished round to
`Backlog/` as always and then starts the next one:

- a new open task with the same title, fields and body; `status` is `open`, `created` and `updated` are today, `due`,
  `remind` and `start` are the next date (the reminder shows it on its day, and the round is **not ready before it**: `next`
  and `list --ready` leave a task out whose `start` day has not come, `next` says `later: N task(s) ...`), and `commits`,
  `done_in`, `waits_for` and `blocked_by` are gone (they belong to the finished round);
- every ticked box in the body (`- [x]`, also the steps of `## Plan`) is open again; the finished round keeps its ticks;
- the slug is `<base>-<due>` (`sweep` becomes `sweep-2027-01-05`, the round after it `sweep-2027-03-02`): an open task and
  a finished one may not share an id (`duplicate-id`), so every round has its own. Anything that names the routine by id
  (`blocked_by`, a typed id) names a finished round afterwards; `plan:` is carried over, so the plan stays open;
- `done_preview` names it (`next_round.due`), `done` reports it (`next_round`), the CLI prints `next-round`;
- `--last` (`done_flow` option `last`) ends a routine: no next round. A failure to write the next round never undoes the
  finish: a note says so (`the next round of ... was not started`), and the routine continues with `new`.

The next round of a folder task is a plain task file: its assets stay with the finished round.

**A ladder** (`repeat: 1w,4w,12w`, 2 to 12 intervals, comma separated without spaces) is a routine with an end: each
round takes the next interval, counted in `repeat_step` (the open round; absent: 1, written by `done` into the next
round). The first round is due when you say (`due`, or `repeat_after` below); finishing it starts the second round due
the finish plus the second interval, and so on. Finishing the last round ends the routine as `--last` does: no next
round, `done_preview` says `ends_routine`, the CLI prints `routine-ended`. Counted from `due` (`repeat_from: due`) a
ladder goes on by the next interval once, it skips no round. Learning paths repeat this way (`LP-14`: after one week,
one month, three months: `repeat: 1w,4w,12w`).

**A start after something** (`repeat_after: <area>/<slug>` for a task or a learning path, `<area>/<slug>#<key>` for a
point of a path) lets a routine wait without a due date: no `repeat-without-due` while it waits. When that is finished
(the task by `done`, a point by `paths.point` or the write door's `node_set`, or the task it was promoted to by `done`,
the path by `path_close`), the engine writes `due`, `start` and `remind` = that day plus the first interval
(`tasks_nvim.routine_after`; the finish reports it as `routines_started`, the CLI as `routine-started`). A point counts
as finished when it is closed and something of it was learned or seen (a stage: all its leaves); a point dropped in
full starts nothing. `repeat_after` stays in the first round and is not carried into the next. A routine with a `due`
is never touched again. `new --repeat=1w,4w,12w --repeat-after=<ref>`, `set <id> repeat_after=<ref>`.

`check`: `bad-repeat` (error, also a `repeat_from` that is neither word, a `repeat_step` past the ladder and a
`repeat_after` that is no reference), `repeat-without-due` (warning: the first round has no deadline; not while it waits
for `repeat_after`), `repeat-from-without-repeat`, `repeat-after-without-repeat`, `repeat-step-without-ladder`
(warnings), `repeat-after-unknown` (warning: `repeat_after` names nothing that exists, the routine never starts) and
`repeat-after-missed` (warning: what it waits for is finished, but it has no `due`, e.g. after a hand edit; the message
names the due date to set). Not built: deleting with a warning, a history of the rounds beyond
the Backlog files. `start` counts for every task, not only for rounds: a task whose earliest day to begin is ahead is not offered by `next`
and not listed by `list --ready` (a clock-dependent answer, `--today` fixes the day).

### The series of the figures (`_Telemetry/history`)

The engine knows the vault as it is now. How many tasks were ready three weeks ago cannot be worked out afterwards:
readiness hangs on the blockers of that day. So the figures of the overview are written down when they change
(`tasks_nvim.history`) and read back as a series (`tasks.history` of the contract, `tasks history` on the command line).

**Where, and why there** (decided 2026-11-18): in the vault, `<vault>/_Telemetry/history/YYYY-MM.jsonl`, one JSON
object per line. In the vault because every reader has it then: a second machine after `git pull`, and the web variant,
which runs the engine in the browser and has neither a hub nor git. A file beside the hub or per machine would give
every machine its own series with its own gaps; reading the history of the repository on demand needs git and minutes.
`_Telemetry` is no area (it has neither `ROADMAP` nor `Backlog`, and a name with a leading `_` never is one).

**A row** holds the figures of one area on one day, absolute, never a difference:

```json
{"area":"lib.nvim","at":"2026-11-18T10:35:25Z","day":"2026-11-18","days":12.5,"open":20,"state":{"ready":9,"waiting":7,"stuck":1,"decision":1,"parked":2},"status":{"open":12,"doing":2,"blocked":3,"decision":1,"parked":2},"v":1,"value":40,"with_effort":15,"with_value":14}
```

`status` counts by `status:`, `state` by readiness (the figures of the plan head), zero counts are left out; `days`
and `value` are the sums of the written efforts and values, `with_effort` and `with_value` how many tasks carry one.
`at` is when the row was written (UTC), `src: "git"` marks a row filled in from the repository. No path of this
machine is in a row.

**When a row is written**: only for an area whose figures differ from its last row (an area that had figures and is
gone gets a row of zeros), and the writer keeps at most one row per day and area: a second run on the same day
replaces the row of that day. Nothing runs by itself; three things write:

| What | When |
|---|---|
| `tasks history record` | by hand or from a script; makes the folder on the first run |
| `tasks index` (no area, or `--all`) | it read every task anyway; only in a vault that keeps a series (the folder is there), `--no-history` leaves it out, and a failure is a warning, never the reason for the index to fail |
| the operation `history_record` of `tasks-ops/1` | what a hub sends (its engine is warm, so the count costs little) |

A full count reads the whole vault (seconds on a big one), which is why `new`, `set` and `done` do not write a row.

**Two machines**: both may write the same day before they see each other's commit. The vault's `.gitattributes`
merges the files by union (`_Telemetry/history/*.jsonl merge=union`): both lines stay, no conflict, and the reader
takes the row with the later `at` (the same second: the same line on every machine); a row written on its day always
wins over one filled in from the repository. The next row written for that
day leaves one line. Commit the files with the rest of the vault; a row that is committed late or never costs a step
in the curve and nothing else, because rows are absolute.

**Reading** (`history.read`) is the one place that judges a line: a line that is no row (not JSON, an unknown
version, a count below zero or beyond 1e9, an unknown status or state word, a day of another month than its file, a
line longer than 2048 bytes, the markers of a merge without union) is named as `<file>:<line>: <why>` and skipped,
at most 20 by name and the rest counted. The writer leaves such a line where it is: it may be a row of a newer engine.
A `_Telemetry`, a `history` or a month file that is a link is not read and not written.

**Levels** (`history.levels`): the level of a day is the sum over the areas of the last row each has up to that day.
A day before the first row has no level; a day without a row carries the level over and says so (`recorded: false`
in the document). What the files themselves say about a day (finished on it, created on it) needs no row and is
counted live for every day.

**The past** (`tasks history backfill`, `tasks_nvim.history_backfill`): for every day before today that has a commit
and no row, the tree of the last commit of that day is laid out in a temporary folder (through an index file of its
own: no worktree, no branch, the repository and its working tree stay untouched), counted with the engine of today
and written as rows with `src: "git"` and the commit time as `at`. A day that has a row is never counted again (a row
written on its day is what the vault was; an area it has no row of gets one that ends a count filled in before it), a day without a commit gets none, a tree the engine cannot read is skipped
and named. The day of a commit is the day of its committer time on this machine. Needs `git`; a few seconds for the
first tree, then about a second per day.

### Meetings (`MEETINGS/`)

A meeting is a file of its own, not a task: it has no priority, effort or readiness, it is never "next", and it does
not move to the Backlog when it is done (a meeting is an event with a date, and links to it must hold). The file is
`<area>/MEETINGS/<slug>.md`, or `<area>/MEETINGS/<slug>/<slug>.md` once something was attached to it. The id is
`<area>/<slug>` and shares the namespace of the area with tasks, plans and projects (`vault.has_plan_or_project` asks
for meetings too; `check` says `meeting-id-taken` when a file of another kind has the id).

The meeting holds the list of its tasks (`tasks:`); which meetings a task has is derived (`meetings.by_task`, the task
entry's `meetings` in the contract), as a project does not list its plans: creating a meeting for five tasks changes
one file, and two machines never collide on a list in a task file.

```markdown
---
title: "Sync with Rick"
status: planned            # planned | done | cancelled (done at any time, with or without a result)
date: 2026-11-24
time: "14:00"              # the beginning; none: all day
end: "15:00"               # or: duration: 45m | 2h | 1h30m (at most 7 days); one of the two
tz: Europe/Vienna          # optional; only its form is checked, the clients convert
location: "Room 3"
online: https://teams.microsoft.com/l/meetup-join/...   # http(s); the service is told from the host
tasks: [lib.nvim/install, lib.nvim/licence]
notify: [-15m, -1d@18:00]  # before the beginning, or a day before at a time; at most 5
notify_to: [me@example.org]
image: assets/images/cover.png   # a file below the meeting folder; or icon: handshake
tags: [sync]
recording: https://...
---

Sync on the install.

## Agenda
- [x] State of team 1

## Teilnehmer
- [x] Rick <rick@example.org> (Organisator)
- [ ] Stefan (Ich)

## Unterlagen
- [Slides](assets/slides.pdf)

## Protokoll
## Beschlüsse
## Folgeaufgaben
- [ ] Clarify the licence -> lib.nvim/licence

## Ergebnis
```

The sections the engine reads (German or English headings: `Participants`, `Documents`, `Minutes`, `Decisions`,
`Follow-ups`, `Result`): the agenda and the follow-ups are checkboxes (`-> <area>/<slug>` at the end of a follow-up names
the task made of it); a participant is `Name <mail> (role)`, mail and role optional, ticked = present; a document is a
list line with a link, an address or a path (a path of a machine is never handed on). `has_result`, `has_decisions` and
`has_protocol` say whether those sections hold text (an HTML comment of a template does not count).

`starts_at` and `ends_at` (`YYYY-MM-DDTHH:MM`, or the day of an all-day meeting) are derived, in the wall time of the
file. Nothing about a meeting changes with the day: whether one is past, which notification is due, is for the reader
to say. The services of `online`: `teams` (`teams.microsoft.com`, `teams.live.com`), `zoom` (`zoom.us` and below),
`meet` (`meet.google.com`), `webex` (`webex.com` and below), `jitsi` (`meet.jit.si`), `link` for any other host.

The codes of `check`: a broken file with its own codes (`meeting-bad-status`, `meeting-bad-date`, `meeting-bad-time`,
`meeting-end-and-duration`, `meeting-end-before-start`, `meeting-end-without-time`, `meeting-bad-duration`,
`meeting-bad-tz`, `meeting-bad-online`, `meeting-bad-recording`, `meeting-bad-task`, `meeting-bad-notify`,
`meeting-bad-notify-to`, `meeting-bad-image`, `meeting-bad-icon`), `meeting-id-taken` (error), `meeting-task-dangling`,
`meeting-image-missing`, `meeting-done-in-future` (warnings), and the hints `meeting-done-without-result` (allowed) and
`meeting-overlap` (two planned meetings of an area at the same time).

Writing meetings is `tasks_nvim.meeting_write`, through the write door (`meeting_new`, `meeting_set`, `meeting_close`,
`meeting_capture`, `meeting_attend`, `meeting_followups`, `board_save`; [CONTRACT.md](CONTRACT.md#writing-tasks-ops1)):
every change under the lock of the file, on the version read, `updated` stamped, refused when it would bring a fault
`check` names. The minutes are a stream of captures: each one line, with its time, in `## Protokoll`, and a task, a
decision or a question also in the section of its kind, so two devices writing at once lose at most a line. Whiteboards
lie in `assets/boards/` (`<name>.ink.json`, `<name>.excalidraw` or the file of an external app, and `<name>.svg` as its
preview) and are the one asset that is replaced, only on the version read. A follow-up becomes a task with
`refs: [<meeting>]` and its id behind the line (`-> <id>`); the `done` of that task ticks the line, a `move_area`
rewrites it and `tasks:`. `tasks_nvim.meeting_quick` reads one line ("Mo 14:00-15:00 Sync @teams https://... #a/b
!-15m") into a proposal of the fields, for the app, the CLI (`tasks meeting new --quick=`) and `:Tasks meeting new`.

**Series.** A meeting with `repeat` is a series: `repeat` is an interval as the routines write it (`1w`, `2w`, `10d`,
`1m`, `1y`) or a word (`daily`, `weekly`, `monthly`, `yearly`, read as `1d`, `1w`, `1m`, `1y`), `repeat_until` its last
possible day, `except` the days without an occurrence (`except: [2026-12-24]`, at most 200). Its `date` is the first
occurrence; weeks and days count calendar days, months and years keep the day of the month of the first day and stop
at the end of a shorter month (a series of the 31st is on 28 February and on 31 March again). The series is the
template: its occurrences are computed (`meetings.occurrence_days`, `meetings.expand`), and `meetings` lists them in
place of the series (at most 500 of one series per window, the rest named in `incomplete`).

An occurrence has the id `<area>/<slug of the series>-<day>` and no file until the first entry: a capture, a result, an
attachment, a whiteboard, a cancellation (decision F10). Then it becomes the file `<slug of the series>-<day>.md` with
`series: <id of the series>`, the frontmatter and body of the series (the agenda as a template), `date` the day and
without `repeat`, `repeat_until` and `except`; the series stays as it was. Every write of the door takes the id of an
occurrence without a file (`meeting_write.edit` makes the file in the same write as the change, `meeting_write
.materialize` before an attachment); a change that changes nothing makes no file. `if_match` of such an occurrence is
the version of the series file. An occurrence file keeps its place in the series by the day in its slug, so its `date`
may move (a 1:1 a day later) without a computed one standing in for it. A series that is `cancelled` cancels the
occurrences without a file. `check`: `meeting-bad-repeat`, `meeting-bad-repeat-until`, `meeting-bad-except`,
`meeting-bad-series` (errors: `series:` beside `repeat`, or a file that is not `<slug of the series>-<day>` of the same
area), `meeting-series-missing` (warning: the series is gone or no series any more), `meeting-series-off-day` (hint:
the day of an occurrence file is no day of its series any more); a series takes no part in `meeting-overlap`.

### Learning paths (`ROADMAP/paths/`)

A learning path organises knowledge where a plan organises work: `<area>/ROADMAP/paths/<slug>.md` (the folder form
`paths/<slug>/<slug>.md` once something was attached) with the frontmatter of a plan file without stages (`title`,
`status`, `areas`, `target`, `links`, `project`; `phase_order`, `gate` and `phase` are `path-no-stages`) and a tree of
learning points in `## Lernpunkte` (or `## Learning points`). `tasks_nvim.plans` reads and writes it (`kind = "path"`),
`tasks_nvim.paths` lists, makes, changes and finishes them; the id shares the namespace of the area.

```markdown
## Lernpunkte

- [ ] Lua lernen {#lua}
  - [x] [Reference Manual](https://www.lua.org/manual/5.4/)
    > Note: the precedence of `..` and `^`.
  - [~] [Programming in Lua](https://www.lua.org/pil/) – Grund: only chapter 1 was needed
  - [ ] C-Compiler erlernen → learning/c-compiler {#cc}
  - [-] Lua-JIT internals – Grund: not needed for the goal
```

`[ ]` open, `[x]` learned, `[~]` seen and `[-]` dropped (both with a reason, `– Grund:` or `Reason:`), `[!]` blocked.
A node with children has no mark of its own: it is closed when all its leaves are, and shown as learned (all
learned), open (none closed) or partial. Progress is counted apart: learned, seen, dropped, open (blocked ones among
the open and once more as blocked). `{#key}` names a node, `→ <id>` the task it was promoted to (an arrow is a
reference only when an id `<area>/<slug>` follows it and nothing but `{xp=…}`, `{#…}` or the reason after that; any
other arrow, `Test rot → grün`, is text), a `> ` line below it
is its note, `![](assets/...)` an image (only below the path's `assets/`). `tasks_nvim.lernbaum` reads the tree and
writes it back byte for byte (only a node changed by `set_state` is written anew); `paths.point` changes one point
on disk under the file's lock. A path is finished by hand with `paths.close`, like a plan: moved to
`Backlog/FEATURES/` with `closed_kind: path`.

`check` reports the file's faults as errors (`path-...`, `path-id-taken`) and the tree's as warnings, never refusing a
write: `path-reason-missing`, `path-duplicate-key`, `path-bad-key`, `path-bad-mark`,
`path-image-outside`, `path-arrow-dangling` (an arrow to no task), `path-image-missing`, `path-cycle` (promotions
that run in a circle over the `## Lernpunkte` of the tasks they name) and `path-link-missing` (a relative link, to a
book or file next to the vault say, that leads to nothing; the same exceptions as `link-missing`, and the images and
badges the two findings above already cover; a link into a neighbour repo that is not checked out here is the hint
`link-repo-absent`, one per repo, not a warning per link). An arrow before a word that has the form of an id but is none
(`→ tasks/Großschreibung`) is a hint, `path-bad-arrow`: the arrow is read as text. `path-stray-line` (a warning, also
for the `## Lernpunkte` of a task) names a line of the section that is no point, no `> ` note below one and not empty,
with the `{xp=…}` / `{#…}` on it: the tree skips it, so a point whose link label broke across two lines loses its
second half without it. Not stray: HTML comments, headings `###` and deeper, fenced code, and the paragraph
`Fehlt im Bestand: …` (LP-11) up to its blank line.

#### XP, levels and rewards (optional)

A little play for a path, never a duty: a path without XP and without `## Level` works in full. A leaf carries XP as
`{xp=N}` beside its key (a whole number from 0 to 100000, either order with `{#key}`); a promoted task carries its own
as `xp:` in the frontmatter (`tasks new --xp=`, `set xp=`; `promote` takes the point's XP along) and they win over
the point's. Learned counts in full, seen half (rounded down), dropped leaves the sum and the maximum (100 % stays
reachable), open and blocked give 0; a parent sums its children (an `{xp=…}` on a parent is the warning
`path-bad-xp`). `lernbaum.suggest_xp` proposes XP for a form from the effort (XS 10, S 25, M 50, L 100, XL 200, days
×50) or the depth of a point; nothing of it is stored.

```markdown
## Level

- [x] 50 XP · Badge assets/badges/stern.png · Belohnung: großes Eis kaufen
- [ ] 50 % · Fortgeschritten · Badge assets/badges/mond.svg · Belohnung: Kino
- [ ] Pfad fertig · Belohnung: ein Wochenende am See
```

One line per level, the parts apart by ` · ` (or ` | `): the threshold in XP or percent of the possible XP (a tree
without XP counts its points: learned 1, seen one half), then in any order `Badge <file>` (a picture below
`assets/badges/`, drawn as an image only), `Belohnung: <text>` (`Reward:`) and a name. `[x]` says the reward was
granted (`paths.set_reward(id, level, given)`, the op `path_reward`; only the mark changes). The whole section is written from a spec by `paths.set_levels(id, spec)` (`lernlevel.write`, the op `path_levels`, made for a form): the level lines are replaced in place, other text of the section stays, an empty spec removes them. `Pfad fertig` (`Path
done`) is the line for the whole path, reached when every point is closed. `tasks_nvim.lernlevel` reads the section
and evaluates it: the level is the run of levels reached from level 1 on, `next` names the first one not reached with
the XP (or percent) missing, `open_rewards` the rewards reached but not granted. `check` reports `level-bad-line`,
`level-bad-mark`, `level-order` (thresholds that do not rise), `level-badge-outside`, `level-badge-missing`
(warnings) and, for a path with levels, the hint `xp-missing` (points without XP count nothing towards them).

#### Hours and the schedule

A path with a fixed rhythm (weeks, sessions) keeps its sessions as points of the tree and its schedule made from them,
not twice. `{h=N}` or `{h=N-M}` on a point (beside `{xp=…}`, any order; whole hours or one decimal, up to 1000) are
the hours it is planned for, `{done_h=N}` the hours it took (`LP-10`); any node may carry them, nothing sums them up
the tree, a value that is no such number is `path-bad-hours`. `tasks_nvim.path_schedule` makes the table of
`## Zeitplan` from the points with hours one level below a stage (or a stage itself): `Sitzung`, `Dauer` (planned,
and taken), `Ergebnis` (the first child `Nachweis:`, `Aufgabe:` or `Ergebnis:`), `Stand` (`offen`, `teilweise n/m`,
`erledigt`), and a row that sums the hours. `tasks path <id> --schedule --write` (`paths.write_schedule`) writes it
between `<!-- GENERATED:schedule start -->` and `<!-- GENERATED:schedule end -->`; the first time it takes the place
of the hand-kept table of the section. A path without hours has no schedule and no finding about it.

#### Optional subtrees

`{optional}` on a node (beside `{xp=N}` and `{#key}`, in any order; mostly the group of books, `LP-11`) makes it and
its subtree optional: those points count for nothing that says how far the path is: not for the progress, not for a
level in percent, not for `Pfad fertig`. Their XP still count for a level in XP once earned, so reading a book is
worth something without being a duty; nobody has to drop an unread book with a reason. `tree.progress` and
`tree.xp` hold the other points, `tree.optional` the optional ones; a node shows the progress of its whole subtree,
and a parent is closed when its points that are not optional are. `tasks path` prints them in a line `optional`
and marks a stage that is optional as a whole; `:Tasks learn` adds `optional n/m gelernt` to the heading.

```markdown
- [ ] Hintergrund aus der Literatur {optional} {#literatur}
  - [ ] [Ein Buch](../../Literatur/buch.pdf): das Kapitel zur Frage {xp=5} {#lit-buch}
```

#### Machine and safety marks

`{machine=private}`, `{machine=workstation}` and `{machine=wsl}` (several with a comma, `{machine=private,wsl}`) say on
which machine a point may be practised (`MASCHINE-01`: `workstation` is the Tricentis workstation, `private` the
other computer, `wsl` a shell in it); a point without the mark goes everywhere. The mark of a parent holds for its
subtree unless a child names its own. An unknown word is the warning `path-bad-machine`. `{safety}` marks a point
where a mistake is dangerous (mains voltage, soldering, chemistry); it holds for the subtree. `check` warns
(`path-safety-unmarked`) when a point's text says `Sicherheit` and neither it nor a parent carries `{safety}`.

`tasks path <id>` prints every `{safety}` point first (`safety` lines, before `points`). `--machine=<private|workstation|wsl|env>`
(`env` reads `NVIM_MACHINE_ROLE`: empty or `default` is `private`) adds a line `machine <role> hidden N open here M`
and one `todo` line per open point that may be practised there (a point under `{safety}` carries `safety` and the text
of the parent, `under: ...`); points of other machines leave the `without-xp` lines. Progress, levels and `Pfad
fertig` stay as they are: a point that does not go here is closed with `[~]` and its reason (`LP-04`). The operation
`node_set` refuses to close (`learned`, `seen`) a point under `{safety}` unless the request carries `ack: true`
("read").

#### Promoting a learning point (`tasks_nvim.promote`)

`tasks promote <area>/<slug>#<key|n>` (Lua: `promote.promote(container, ref, opts)`) makes a task of a learning point
of a path or of a task's own `## Lernpunkte`:

- the task (`kind: task`, `category: [learning]`, `point: <container>#<key>`) is made in the container's area or
  `--area`, titled after the point's text without its Markdown (`--title`); its body names where it came from, copies
  the point's link and note, and holds the point's **subtree** in its own `## Lernpunkte`, dedented to the root;
- the point's text (its label without Markdown) is the task's summary line, the first line of the body;
- the tags of the container that hold for everything in it, `on-workstation` and `not-on-workstation`, go to the task
  (a path takes `tags:` with `path-new --tags=`); `--tags=a,b` adds more, `--after=id,id` and `--effort=` are taken as
  `new` takes them and judged before anything is written (also in a `--dry-run`); `--no-index` leaves the indexes;
- the point's line gets `→ <task id>`, the mark `[ ]` and a key when it had none; its note stays.

From then on the **task owns the point's state**. `done` writes it into the container: `learned` for no outcome or
`learned`, `[~]` for `seen` and `[-]` for `not-applicable` (the task's `outcome_reason` as the reason; the result names
it as `flow.point`). The rule of the parents is the tree's: a parent is closed when every leaf is, a promoted point
counts as one leaf. A task can promote its own points again (Lua lernen -> C-Compiler -> Sprache C). Finishing a task
whose `## Lernpunkte` still has open points is allowed (R3) and gives the note `finished with N open learning
point(s)`; `tick_all` ticks `## Plan` only, never the learning points. The way to `blocked` and back keeps the point in
step too: `set status=blocked` marks it `[!]`, a `set` out of `blocked` gives it `[ ]` again, and `reopen` of a finished
task gives it `[ ]` (its reason dropped; `[!]` for a reopen as `blocked`). A status change that keeps the point's
state (`open` -> `doing`) reads no container. In `tasks-ops/1` the container is one more id in `changed_ids`.

`--dry-run` names the task and the lines that would move; the result carries its `inverse`. `tasks unpromote
<area>/<slug>#<key>` takes it back while the task holds no work of its own (status `open`, no commits, no assets): the
task's tree as it is now goes back below the point, the arrow goes, the task file is removed. A task that was worked
on is taken back by hand.

`check` (warnings): `promote-point-dangling` (`point:` names no open path or task, or no point there whose arrow names
the task), `promote-state-drift` (the mark of the point disagrees with the task: closed while the task is open, `[!]`
while it is not blocked or `[ ]` while it is, or not the state of its outcome when finished), `promote-cycle` (the `point:` of tasks lead back to one of them),
`task-arrow-dangling` (an arrow in the `## Lernpunkte` of an open learning task names a task that exists nowhere); a
`point:` that is not `<area>/<slug>#<key>` is the error `bad-point`. In the editor: `:Tasks promote` / `unpromote`
(the point under the cursor, or `<id>#<key>`) and the tree view `:Tasks learn` ([COMMANDS.md](COMMANDS.md)).

### Milestones (`ROADMAP/milestones/`)

A milestone is a fixed set of things to finish by a day: its own level beside plans and projects (decision
2026-11-21), not a project with a date. The file is `<area>/ROADMAP/milestones/<slug>.md` (or `<slug>/<slug>.md`);
the id `<area>/<slug>` shares the namespace of the area with tasks, plans, projects, paths and meetings. It never moves
to the Backlog: a reached milestone is an event with a date.

```markdown
---
title: "Release 1.0 der Handy-App"
status: doing            # planning, doing, parked, done
due: 2026-12-15          # the day aimed at
includes: [tasks-desktop/meetings-mobile, tasks-desktop/abnahme, Learning/livecompare]
close: auto              # auto (default): the engine reaches it; manual: milestone_set status=done
reached: 2026-12-12      # written by the engine
---

## Verlauf

- 2026-12-12 reached
```

- **Members** are ids of the same vault: tasks, plans, projects, learning paths, meetings. A member is done when it is
  finished (a task, plan, project or path in the Backlog; a meeting `done` or `cancelled`). No tags or filters: the
  scope is fixed, so the milestone is something to measure against.
- **Progress**: members done of all, and the units below them: a plan or project counts its tasks (open and finished;
  one without any counts as one), a task, a meeting and a path one each.
- **Reached**: every write that can finish a member (`tasks done`, `plan-close`, `project-close`, the operations of
  `tasks-ops/1`) runs `milestones.settle`: a milestone of `close: auto` whose members are all done gets
  `status: done`, `reached` and a line in `## Verlauf`. `close: manual` waits for `milestone_set` with `status: done`
  (refused while a member is open). A milestone without members is never reached; a parked one is left alone.
  A complete milestone of `close: auto` cannot be set back to `planning` or `doing` by hand (decision 2026-11-21:
  refused with `details.hint`); `close: manual` in the same patch keeps it open.
- **Opened again**: a member of a reached milestone that is open again (`reopen`) sets it back to `doing`; `reached`
  stays as its history and `## Verlauf` says which member. A member that exists nowhere holds a milestone open but
  never opens a reached one (that is a `check` error, not a silent change).
- **One vault**: an id of another vault is refused when written and an error in `check`; nothing is read there.
- `check`: `milestone-include-unknown`, `milestone-include-foreign`, `milestone-bad-include`, `milestone-nested`,
  `milestone-id-taken`, `milestone-bad-status`, `milestone-bad-close` (errors); `milestone-include-overlap` (a member
  already in it through a plan or project it names), `milestone-drift` (its status behind its members, e.g. after a
  hand edit), `milestone-overdue`, `milestone-empty` (warnings).
- Headless: `tasks milestone-new <area> "<title>" [--due= --includes=a/b,c/d --close=manual]`, `tasks milestones
  [<area>]`; `tasks done` says `milestone-reached <id>`.

### Folder tasks

A task is a file `tasks/<slug>.md` **or** a folder `tasks/<slug>/<slug>.md` (same name) that
may hold assets, by convention under `assets/`. Both forms live side by side; the id is
`<area>/<slug>` either way. Only `<slug>/<slug>.md` is the task; every other file in the
folder is an asset, never read as a task. `attach <id> <file>` copies a file to
`<slug>/assets/` (turning a plain task into a folder task first) and prints the Markdown link
(`![]()` for images); `folderize <id>` converts without an attachment. The file lies one
folder deeper then, so every relative link of its text (not `assets/`, not in code, see
`tasks_nvim.mdlinks`) gains a `../` and still names the same file; a failed `attach` puts the
file back with its text as it was. The same holds for plans, projects, paths and meetings. `done` moves the
whole folder to `Backlog/<bucket>/<date>_<slug>/<date>_<slug>.md` and puts it back when a
later step fails. `index` links `tasks/<slug>/<slug>.md`. Reasoning: concept section 12.

Relative links follow a file that moves (`tasks_nvim.relink`). `done`, `reopen`, `move_area` (`tasks move`),
`folderize` and an `attach` that makes the folder form rewrite the relative links of the files below `ROADMAP/` and
`MEETINGS/` of every area that named the moved file (or a file in its moved folder, an asset say), and the links of
the moved file itself, which sits in another folder now. A link is rewritten only when it would name another file
after the move; it is then written the shortest way, with its `#anchor` and a leading `./` kept. So `reopen` after
`done`, or `move_area` back, gives every text as it was: each is the other's inverse. The history below `Backlog/` is
not read on every move (it is most of a vault): `tasks relink [<area>] [--dry-run]` mends the dead links there and
anywhere else once. It rewrites a dead link to a `.md` file whose slug names exactly one file (`<slug>.md`, its
folder form, or `<date>_<slug>` in a Backlog; one in the area the link named wins over others), and a dead link of a
finished file that named a file from the folder it was open in (`../reports/x.md` written in `ROADMAP/tasks/`);
ambiguous and unresolved links are listed, never guessed. `relink = false` in the options of `done`, `reopen`,
`moves.move` and `folderize` leaves the links alone.

An asset name (`--name=`, else the file's own name; spaces become `-`) may use letters,
digits, `_`, `.`, `-` and non-ASCII; no separators, no `..`, no trailing dot, and no name
Windows treats as a device (`nul`, `con`, `aux`, `prn`, `com1`-`com9`, `lpt1`-`lpt9`, with or
without an extension): writing to `nul` "succeeds" and stores nothing. The same names are
never generated as a slug (`new "Nul"` gives `nul-task`) and are refused as `--slug=`. An
existing asset is never replaced. A failed `attach` leaves the task as it was: the folder
conversion it started is undone (and said so in the error when that fails too). The editor
command gets the file argument already resolved by the composer (`~`, `$VAR`, `%VAR%`) and
never expands it a second time: `report[1].pdf` is that file, not `report1.pdf`, and a backtick
in a name never reaches a shell.

### `done` (rule R6)

`status: done`, `done_in`, `commits` (when given: every commit made for the task, `repo@sha` each, added to the
task's own list), `updated`; the file moves to `Backlog/FEATURES/`
(`feature`, `idea`, `research`) or `Backlog/TASKS/` (`task`, `bug`, and tasks
without a kind) as `YYYY-MM-DD_<slug>.md`; the row goes on top of that
section of `Backlog/README.md` (count recomputed, `_noch leer_` replaced by a
table, line endings kept); the area index is regenerated.

Failure safety: the finished copy, the README and the index are snapshotted with
`lib.nvim.checkpoint` first and restored byte-exact when any step fails. The task file
itself is deliberately not part of the snapshot (a restore would overwrite whatever was
written to it since): it is checked once more right before it is removed or moved -- when
it changed since `done` read it (the editor saved, another run), `done` stops with
`changed while it was being finished` and changes nothing -- and put back by hand only if
`done` already removed it. A folder task moves with a plain rename and is moved back by
hand-written steps (original file name and text first, the finished copy dropped only after
that); what cannot be undone is named in the error as `rollback incomplete: <path> (...)`,
never left silent.
Re-running a finished task answers `already` and changes nothing; if an earlier
run died after creating the Backlog file but before deleting the old one, the
next run completes it. A target that exists with different content, or a
finished task with the same id under another date, is refused.

#### How it ended (`outcome`)

`done` stays the only finished status. Beside it, `outcome` says how the task ended:

| `outcome` | Meaning | `outcome_reason` |
| --- | --- | --- |
| (none) | done as meant: every task finished before outcomes existed | -- |
| `learned` | done as meant, said out loud (a learning task that was learned) | optional |
| `seen` | looked at, not done ("I looked at it, but X keeps me from it") | required |
| `not-applicable` | does not apply | required |

`tasks done <id> --outcome=seen --reason="..."` (Lua: `mutate.done(id, { outcome, outcome_reason })`) writes both
keys into the finished copy. `seen` and `not-applicable` without a reason are refused, unless the task carries an
`outcome_reason` already; a blank reason is no reason. `--reason` alone completes the outcome the task names. A
finish that names neither writes neither, byte for byte as before. The outcome may be noted on an open task in
advance (`set outcome=seen`, `new --outcome=`); `check` then gives the hint `outcome-on-open-task`.

The Backlog row names it after the date (`(2026-11-19, seen: no Mac)`), `list --done` shows it on the status
(`done:seen`) and filters with `--outcome=learned,seen,not-applicable|none` (`none`: no outcome written).
`done_preview` and the result of `done` carry `outcome` and `outcome_reason`. The next round of a routine starts
without them. The contract (`tasks.finished`, `donepreview`) does not carry the fields yet.

#### The CI state of the commits (`ci`)

`commits` names what was pushed for a task, not whether the CI of those commits passed. The optional key `ci` says it:
`pending` (pushed, no verdict yet: the hosted CI still runs or waits for a runner), `green` (the CI passed on every
system) or `red` (it failed). No `ci` reads as "not known", as for every task finished before the key existed.

`tasks done <id> --commits=... --ci=pending` writes it with the finish (an agent finishes so as long as the CI has not
answered); without `--ci` the task's own `ci` stays as it is. The verdict follows later with `tasks set <id> ci=green`
(or `red`, or `ci=` to take it away): `ci` is bookkeeping like `remind`, so `set` changes it on the finished task in
`Backlog/` too, without touching `updated` (`mutate.BOOKKEEPING`). `list --done` shows it on the status (`done ci=red`,
`done:seen ci=green`) and filters with `--ci=pending,green,red|none`: `tasks list --done --ci=pending,red` lists what
still waits for a verdict or is red. `show` prints `ci:`. The next round of a routine starts without it. `check` refuses
another word (`unknown-ci`). The contract carries it on task entries and on `tasks.finished` (capability `ci`); the
write door's `done` takes `ci`, its `set` takes `ci` in the patch.

### The marker file `tasks-vault.json`

An optional file in the vault root marks a folder as a tasks vault. Without it every folder works as before; with it the
vault carries its layout version and a few defaults, and travels with the clone (it is data of the vault, not of a machine):

```json
{
  "ci": { "strict": false },
  "extra_areas": ["ALL"],
  "kind": "tasks.vault",
  "lang": "de",
  "layout_version": 1,
  "plugin": "tasks.nvim",
  "schema": 1
}
```

`schema`, `plugin`, `kind` and `layout_version` are required, the rest is optional (`schemas/tasks-vault/1`, with
`example.json`; `contract/check.mjs` holds the same rules against it). What the engine takes from it:

- `extra_areas` are areas like those of `setup({ extra_areas })` and `$TASKS_EXTRA_AREAS`; the three are **merged**, a name once.
- `lang` is the language of the body of a new task when the caller names none (`new --lang`, `lang =` win).
- `ci.strict` makes `tasks ci` fail on warnings as `--strict` does (the flag cannot switch it off). `trust_vault_lint` is **no key**: code from a
  synced vault runs only with an explicit trust (`setup({ ci })`, `--trust-vault-lint`, `$TASKS_TRUST_VAULT_LINT`).

The file is foreign data in a synced folder, so it is read **fail closed**: an unknown key (at any level), a `schema` or
`layout_version` newer than the engine knows, a foreign `plugin`, a bad area name, a file over 64 KiB, a link (symbolic
link, junction) or text that is not JSON (a merge conflict) makes the whole vault unusable. Every call answers
`tasks-vault.json: <reason>` (`vault.root` returns it; in the contract it is `invalid_argument` with that message), and the
message names the key or the version, never a path. `hello` is the one call that still answers: its `marker` says
`present` and `layout_version` or the `problem`. A vault that has **no** file is told once by `check`
(`vault-marker-missing`, a warning), one with an older layout version too (`vault-marker-outdated`); `:checkhealth` shows the state.

The engine writes the file once: `:TasksVault create` and `init-vault` make it for a new vault (`--lang` is its `lang`), never over a
file that is there (also not a refused one). Nobody else writes it: a person edits it like a task file.

- `TEMPLATES/task.md` of the vault is the body of a new task (`new` without `--body`), `TEMPLATES/task-<kind>.md` for
  that kind first; only with the marker file; the frontmatter of the template is dropped, `{title}` and `{date}` are replaced,
  an empty, linked or over 20000 characters template is not used.

### Findings of `check`

| Code | Meaning |
|---|---|
| `frontmatter-missing`, `frontmatter-invalid`, `title-missing`, `status-missing`, `field-type`, `unreadable` | the file cannot be read as a task |
| `symlink-task` (error) | the task file is a symbolic link or a junction: it is not read (the vault must not point outside itself); the task is invalid and has no `etag` |
| `unknown-status`, `unknown-kind`, `unknown-category`, `unknown-severity`, `bad-prio`, `bad-effort`, `bad-value`, `bad-actor`, `bad-date`, `bad-link` | a field has a value outside its enum / format (`bad-link`: a `links` entry that is no `http://` / `https://` address) |
| `start-after-due` | the `start` date is later than the `due` date |
| `bad-time` | `remind_at` is not a time of day (`HH:MM`, 00:00 to 23:59) |
| `bad-email` | a `remind_to` entry is not an e-mail address, or the list names more than 10 |
| `remind-to-without-remind` (warning) | `remind_to` on a task without a `remind` day: nobody is reminded until a day is set |
| `remind-at-without-remind` (warning) | `remind_at` on a task without a `remind` day: it says nothing until a day is set (`set remind=` takes the time away with the day) |
| `effort-without-plan` (warning) | an open task that is not `parked` is bigger than L (`XL`, or more than `3d`) and has no `plan:`; it belongs in a plan, nothing is converted |
| `overdue` (warning) | an open task that is not `parked` has a `due` date before today (`tasks.check` takes the day from the request, so a golden stays the same all year). It changes with the calendar, not with a commit: under `tasks ci --strict` (warnings fail) a task turns the run red on the day after its `due` |
| `blocked-by-cycle` (error) | the hard edges form a circle; one finding per cycle, the members named (a task that blocks only itself is `blocked-by-self`) |
| `doing-while-blocked`, `blocked-without-blocker`, `blocker-freed`, `blocked-by-parked` (warnings) | the status runs behind what the blockers say; each is a warning because a status may trail the facts for a moment, a cycle may not. `blocked-by-parked` leaves out a task that is `parked` itself (a chain shelved on purpose, e.g. with the same `waits_for`) |
| `actor-cdx-waits-on-me` (warning) | a task written `actor: cdx` waits on an open task that only you can do (`model.actor` = `me`) |
| `ui-tag-without-ux` (warning) | an open task has a UI tag (`ui`, `ui-kit`, `webui`, `page`, `overlays`, `dashboard`; `check.UI_TAGS`) but not the category `ux`: the category is the one source for "touches the surface", a tag only says which part |
| `ui-word-without-ux` (hint) | a word of `check.UI_WORDS` (Fenster, Knopf, Button, Dialog, Ansicht, Oberfläche, UI, view, window; German nouns also at the end of a compound) is in the title of an open task with neither the category `ux` nor a UI tag. A hint is never an error or a warning: it is in `result.hints`, shown by `:Tasks index --check` and the CLI `check` as `info`, and not in the document `tasks.check`. `setup({ check = { ui_words_off = { "<vault name or folder>" } } })` switches it off for a vault |
| `severity-without-bug-or-security` (warning) | `severity` on a task that is neither `kind: bug` nor in the bug / security category |
| `unknown-ci` (error) | `ci` is none of `pending`, `green`, `red` |
| `invalid-waits-for` (error) | `waits_for` is not one key: a lower-case word of a-z, 0-9 and `-`, at most 40 characters, not `none` |
| `waits-for-without-parked` (warning) | `waits_for` on a task that is not `parked`: only a parked task waits (the engine drops the key when the status leaves `parked`; this is a file edited by hand) |
| `unknown-outcome` (error) | `outcome` is none of `learned`, `seen`, `not-applicable` |
| `outcome-without-reason`, `outcome-on-open-task` (hints) | an open or finished task with `outcome: seen` / `not-applicable` and no `outcome_reason`; an outcome on an open task (allowed: a note made in advance, `done` writes it for real). Hints like `ui-word-without-ux`: in `result.hints`, never a warning |
| `slug` | filename is not a kebab-case ASCII slug, or the file lies in a subfolder of `tasks/` other than `<slug>/<slug>.md` |
| `slug-conflict` | the same slug exists as a file and as a folder task |
| `asset-dangling` (warning) | a folder task links `assets/<file>` that is not there |
| `link-missing` (warning) | a relative Markdown link or image of an open task leads to no file (with its line); not checked: links in code, `http(s):`, `mailto:` and other schemes, `#anchor`, and a folder task's `assets/` links (`asset-dangling`) |
| `link-repo-absent` (hint) | links of the files above and of learning paths (`path-link-missing`) lead out of the vault into a folder that is not there at all: the first folder outside the vault they name, a neighbour repo (`../Literatur`) not checked out on this machine. They are no warnings; one hint per folder counts them, "repo ../Literatur is not checked out: n link(s) in m file(s) unchecked (line N: the first in this file)", on the first file (by path). The folder is named from the vault, never as a path of the machine. When the folder is there and only the file is missing, it stays `link-missing` / `path-link-missing`. A hint never fails `tasks ci`, not even with `--strict` |
| `plan-link-missing`, `project-link-missing`, `meeting-link-missing` (warnings) | the same for a plan, project or meeting file, with its line; the `cover` and `icon` asset it names are left to `cover-missing` / `icon-missing` (`meeting-image-missing`, `meeting-icon-missing`). A block indented by four spaces counts as text, not code: in the vault such lines are the continuation of a list item and hold real links |
| `asset-unused` (warning) | a folder task has an image in `assets/` that its text never mentions |
| `view-invalid` (warning) | a file of a saved view (`<area>/ROADMAP/views/*.md`) is no view: a field or value the engine does not have, no frontmatter, a symbolic link, or a folder of views that leads out of the vault (the reason is in the message; `tasks.views` lists it under `problems`) |
| `index-stale`, `index-error` | `ROADMAP/TASKS.md` is missing, outdated or left over / could not be checked |
| `bad-blocked-by`, `blocked-by-self`, `blocked-by-dangling` | the blocker is malformed, the task itself, or exists nowhere |
| `blocked-by-done` (warning) | the blocker is already finished |
| `wikilink-dangling`, `wikilink-ambiguous` | a bare `[[slug]]` in `blocked_by`, `after` or `plan` (or a plan file's `target`) names no task or plan, or one in several areas (the candidates are named); a wikilink that names one id is checked as that id with the codes of the field |
| `done-in-roadmap` | `status: done` in `ROADMAP/tasks/` |
| `open-in-backlog` | a task file in `Backlog/` whose status is not `done` |
| `duplicate-id` | an open and a finished task share an id |
| `frontmatter-warning` (warning) | a frontmatter line was kept but not understood |
| `area-groups-invalid` (error) | `<vault>/area-groups.json` cannot be read or parsed, or one of its groups (or one of `setup({ area_groups })`) is malformed; whole-vault runs only, area `""` |
| `claim-expired`, `claim-orphan`, `doing-unclaimed` (warnings) | a claim that ran out, a claim file of a task that is not open, a `doing` task nobody claimed for seven days. See [Claims](#claims) |
| `bad-repeat` (error), `repeat-without-due`, `repeat-from-without-repeat`, `repeat-after-without-repeat`, `repeat-step-without-ladder`, `repeat-after-unknown`, `repeat-after-missed` (warnings) | `repeat` is neither an interval nor a ladder (or `repeat_from` is neither `done` nor `due`, `repeat_step` is past the ladder, `repeat_after` is no reference); a routine with no `due` date that waits for nothing; `repeat_from` / `repeat_after` on a task that is no routine, `repeat_step` without a ladder; `repeat_after` names nothing, or names something finished while the routine has no `due`. See [Routines](#routines-repeat) |
| `vault-marker-missing`, `vault-marker-outdated` (warnings) | the vault has no `tasks-vault.json`, or it names an older layout version than this engine writes; vault-wide, so the finding has `area: ""` and `file: tasks-vault.json` and a check of one area leaves it out |
| `area-groups-config` (warning) | a group of `setup({ area_groups })` is malformed (the file is fine; a `setup()` group that replaces one of the file by name is no finding) |
| `area-group-shadowed`, `area-group-empty`, `area-group-unknown-member`, `area-group-nested` (warnings) | an area group has the name of an area (the area wins), matches no area, names an exact area that does not exist, or names another group (groups do not nest); whole-vault runs only |
| `title-comment` (warning) | the title has a trailing YAML comment: ` #` starts a comment, so `title: Fix bug #12` reads `Fix bug`; quote the title (`title: "Fix bug #12"`) when the `#` belongs to it. `new` and `set` quote automatically; only hand-written files are affected |

Only `error` findings make a run fail.

### `--stale=refs` -- tasks whose referenced files changed

`--stale=<days>` looks only at `updated`. `--stale=refs` (or `--stale-refs`) asks the
other question: a task with `refs: [lua/ai/config/init.lua, docs/a.md]` is stale when one of
those files changed on a **later day** than the task's `updated` (else `created`), so the task
needs a fresh read. The two combine (both must hold). The output names which file changed:
`list` appends `changed: lua/a.lua (2026-10-01, git)`, the editor listing puts the files under
the heading, and the dashboard shows the chip `[stale: refs]` (toggle it with `f` > `stale-refs`).

How a ref is read:

| Ref | Handling |
|---|---|
| `lua/a.lua`, `docs/x.md`, `lua\a.lua`, `dir/` | a path: backslashes become `/`, a trailing `:42` or `#anchor` is dropped |
| `lib.nvim@803de65`, `https://...`, `filetree.nvim:cheatsheet-paged` | skipped (a commit, a URL, an anchor: nothing on disk to date) |
| `\\server\share\x`, `//server/share/x`, `\\?\C:\x`, `\\.\pipe\x` | skipped: a network or device path. A stat on it makes Windows connect to a host the task's author chose (SMB, NTLM credentials, a long wait) |
| `/etc/hosts`, `C:/Users/x/.ssh/id_rsa` | an absolute path is looked up only inside the places below the engine was told to look in (the folders that hold the repos, the nvim config, the vault, `extra_bases`), after its `..` are resolved; anywhere else it is "found nowhere" |
| a task id like `ui.nvim/some-slug` | found as no path, so it is only counted as "found nowhere" |

A path is looked for, in order, in: the repo named like the task's area (`<repos>/<area>`, where
`<repos>` is the folder above the vault's checkout, `$REPOS_DIR` and `$REPOS_DIR/repos`), the nvim
config (`$NVIM_CONFIG_DIR`, optional), the vault, and the folder above the vault. The first place where it
exists wins. A file is dated by the commit date of the last commit touching it (a directory: the
newest file in it); a file git does not know (untracked, or a base that is no repository) uses its
mtime. Uncommitted edits are not seen.

Cost: one `git log` per repo and 100 paths, never one per task; a file is looked up once however
many tasks name it; at most `staleness.MAX_REFS` (1000) distinct files are checked per run (the
rest is reported). All git calls of a run share a time budget (`staleness.budget_ms` of `setup()`, 30 s):
once it is used up the remaining files are dated by their mtime. In the editor (`:Tasks list`, the dashboard, `plan`, `estimate`, `quickwins`) the
check never makes Neovim wait: it runs in the background (`staleness.compute_async`, every git call a `vim.system`
callback), the dashboard first shows the list the last answer kept (before the first: every task the other filters
keep, `(checking refs ...)` in the title) and redraws when the answer comes; `--to=`/`--format=` deliver once it is
there. `:Tasks plan`, `:Tasks estimate` and `:Tasks quickwins` take the same way: every other criterion first, the
refs of what is left in the background, then the scope again with the dated refs; a newer command of the same name
cancels the delivery of the older one. The headless commands stay synchronous. A missing repo, file or git only
produces a note on stderr / a notification, never an error. Two semantics worth knowing: a task with neither
`updated` nor `created` has no date to compare with, so any dated change counts (the same way `--stale=<days>`
counts an undated task as stale); and when the check itself fails, `model.filter` keeps the tasks that carry refs
and marks them `unverified` (fail-open: an unreadable signal never hides work); a path git refuses costs only its own
date (the call is halved until that path stands alone). A ref with `..` that leaves its repo
(`../lib.nvim/lua/x.lua`) is dated from the folder the file really lives in. `model.filter` looks
up only the tasks the other criteria kept, so `--status=doing --stale=refs` checks far fewer refs
than `--stale=refs` alone. Against the real vault: about 600 files in ~3.5 s.

## CI gate -- `tasks ci` / `scripts/tasks-ci.lua`

```sh
nvim --headless -u NONE -l scripts/tasks-ci.lua --vault=<vault>
```

Three steps, exit `0` only when all pass (`1` otherwise), a short summary at the end:

1. `check` -- every `error` finding fails (`--strict`: warnings too)
2. `index --check` -- no `ROADMAP/TASKS.md` missing, outdated or left over
3. `md_lint` -- `<vault>/TOOLS/scripts/md_lint.lua` over every generated `TASKS.md` (relative
   links, anchors, table columns; `$VAR/...` links when lsp.nvim is on `$REPOS_DIR` or in lazy's
   data folder). `--no-lint` skips it; a missing script fails the run, it is never skipped silently.
   `--md-lint=<file>` points at another copy. A linter that runs longer than 120 s
   (`ci.lint_timeout_ms` of `setup()`, `opts.timeout_ms`) is killed and the step fails with
   `timed out`; one killed by a signal fails as well (a signal reads as exit code 0 on POSIX).

A pipeline for a vault repo runs `scripts/tasks-ci.lua` with `TASKS_VAULT` set (checkout this plugin and `lib.nvim` next to it).

**Trust.** Step 3 *runs* `md_lint.lua` as Lua (`nvim --headless -u NONE -l <script> <files>`) with the rights of
whoever runs the pipeline. With the default path that script comes out of the vault itself, so a pipeline that
checks out a vault from a pull request or a fork would run the contributor's code. That is why `ci` **refuses**
to run the vault's script until you say you trust it: `--trust-vault-lint` (or `$TASKS_TRUST_VAULT_LINT=1`, or
`ci = { trust_vault_lint = true }` in `setup()`). A script you name yourself with `--md-lint=<file>` is trusted by
being named (keep it outside the vault); `--no-lint` skips the step.

## Headless CLI -- `scripts/tasks.lua`

For sessions without a running Neovim (rule R12) and for CI. One
implementation: the script only sets `runtimepath` (this plugin and
lib.nvim) and calls `tasks_nvim.cli`.

```sh
nvim --headless -u NONE -l scripts/tasks.lua list --status=doing,decision
nvim --headless -u NONE -l scripts/tasks.lua new lib.nvim "Notify: unify channels" --kind=feature --prio=2 --tags=ui
nvim --headless -u NONE -l scripts/tasks.lua set lib.nvim/notify-unify-channels status=doing
nvim --headless -u NONE -l scripts/tasks.lua done lib.nvim/notify-unify-channels --done-in=lib.nvim@abc1234
nvim --headless -u NONE -l scripts/tasks.lua index --check
nvim --headless -u NONE -l scripts/tasks.lua check
```

| Command | Effect |
|---|---|
| `list [area] [--status=a,b] [--prio=1,2\|<=2] [--effort=S,M\|<=M] [--kind=k] [--category=c,d] [--severity=high,critical] [--value=4,5\|>=4] [--actor=cdx,me,pair,none] [--tag=t] [--stale=N|refs] [--stale-refs] [--blocked] [--reminders] [--sort=default\|prio-effort\|severity\|frecency\|roi] [--format=tsv\|ids\|json] [--limit=N --offset=N] [--done]` | open tasks, sorted; `id status prio effort kind updated title`, tab-separated. `--format=json` is the `tasks.list` document of the contract (plan order unless `--sort` names another, pages of at most 100), `list all` / `--done` the finished tasks of the Backlogs |
| `lists [save <name>\|delete <name>\|rename <old> <new>\|show <name>] [filters] [--sort --area --desc]` | the named lists (name, source, summary); `list`, `plan` and `estimate` take `@<name>` as their first word and run the list, options typed on top win |
| `quickwins [area] [filters] [--min-value --max-effort] [--format=tsv\|md\|ids] [--by-actor] [--paths] [--report=<file>]` | the quick wins, best roi first, plus the small tasks that miss a value; default status `open,doing,decision` |
| `index [area] [--check]` | write / verify `ROADMAP/TASKS.md` (all areas without argument) |
| `index <area> --staged` | build that index from the git staging area and stage it, the working tree stays as it is: in a shared checkout another session's uncommitted tasks stay out of the commit (headless only). It lists the staged files of the area it counted (`staged<TAB><path>`): after an autostash that hit a conflict, the rest of the tree is staged too, so unstage what is not yours (`git restore --staged <path>`) and run it again. A conflict in a task file is refused; one in the generated index alone is resolved. When the tree's index file is not the staged one it says so: `check` reads the tree and calls it stale until the tree catches up (in a checkout of your own: `git checkout -- <path>` after the commit) |
| `index [<area>] --staged --check` | whether the staged `ROADMAP/TASKS.md` of the area (without one: of every area with a staged change below `ROADMAP/`, a `done` move included) is the one its staged task files render to. Writes and stages nothing; one line `stale<TAB><area><TAB><n> open<TAB><path> (<reason>)` per area that is not (reason `missing`, `outdated`, `orphan`, `conflict`), the command to fix it, and exit 1. It checks out only the vault's top files and the area's `ROADMAP/` (about 1.5 s in the real vault, where `--staged` used to take 15 s for the whole checkout), so the vault's pre-commit hook runs it on every commit. Inside a commit it reads `$GIT_INDEX_FILE`: a `git commit -- <paths>` is checked as it really is |
| `commit <path>... --message=<text> [--dry-run]` | commit only these paths of a shared vault (files or folders, relative to the vault; deletions and the moves of `done` included) from a staging area of its own (`GIT_INDEX_FILE`), so another session's staged files stay staged and out of the commit (`tasks_nvim.vault_commit`). It adds the `ROADMAP/TASKS.md` of every area the paths touch below `ROADMAP/`, rendered from that commit; the `Backlog/README.md` of those areas as `HEAD` has it plus the rows of the backlog files the commit adds (from the tree's README, where `done` wrote them) and minus those it removes, so another session's row stays out; the changed `_Telemetry/history/*.jsonl`. `HEAD` moves by compare-and-swap (`commit-tree`, `update-ref HEAD <new> <old>`): when another session committed meanwhile the commit is built again on top. Signed when `commit.gpgsign` is set; runs no hooks; does not push. Afterwards the committed paths match `HEAD` in the shared staging area. Prints `committed`, `path` per changed file, `index` per area, and a note for generated files whose copy in the tree is not the committed one |
| `hook install\|status` | the vault's pre-commit hook in `<git-common-dir>/hooks/pre-commit` (shared by linked worktrees): it runs `index --staged --check` and refuses a commit with a stale staged index. It finds tasks.nvim through `$TASKS_NVIM_DIR`, `.deps/tasks.nvim`, `../tasks.nvim`, then the checkout that installed it; without one, or with one too old to know the check (exit 2), it lets the commit pass with a note. `install` never overwrites another pre-commit hook (`foreign`, exit 1) and brings an older one of its own up to date; `status` prints `installed`, `outdated`, `absent` or `foreign` (exit 1 unless installed). With `core.hooksPath` set it notes that the global folder must hand over to `.git/hooks` |
| `new <area>[,<area>...] <title> [--kind --prio --effort --tags=a,b --category=c,d --severity=s --value=1..5 --actor=cdx\|me\|pair --refs=a,b --links=https://...,... --lang=de\|en --summary --slug --status] [--folder] [--no-index]` | create a task file (`a,b` makes one task with the same text in each area, every area is checked first and a bad one writes nothing; `--lang` picks the language of the body headings, default `de`; `--folder` a folder task) |
| `plan [area] [--for=id] [filters] [--ready] [--format=md\|tsv\|ids]` | the plan: ready now, decisions by leverage, stages, critical path |
| `next [area] [--n=3] [--actor=cdx\|me\|pair\|none] [--format=json]` | `next: <id> <title> <reason>`, `then: ...`, `freed:`, `cdx:`, `empty:` and `remind:` lines; `remind: <id>\t<title>\t<date>` lists the open tasks whose reminder is due (oldest first, judged by `--today`, which must be a date), a last `remind: N finished task(s) with a reminder due (`list --done --reminders`)` counts the finished ones; `--format=json` is the `tasks.next` document (no `remind:` there) |
| `estimate [area] [--for=id] [filters]` | the estimate line, `quick wins:`, `unestimated:` |
| `path-new <area> <title> [--slug --areas --target --project --tags --status --summary --links --icon --cover --template=learning] [--no-index]` | create a learning path under `ROADMAP/paths/` through `paths.new` (no stages: `--phases` is no option); the editor's `:Tasks path-new` makes it and opens it. `--no-index` is accepted for scripts and changes nothing: a new path is in no index |
| `path-new <area> --from=<draft.md> [--slug=s] [--dry-run]` | a whole learning path from one draft file (`tasks_nvim.path_draft`): the slug as `path-new` gives the draft's title, `status`/`created`/`updated` added when missing, then `check.path_file_findings` on the text as if it were in place. Any error or warning refuses it before anything is written: one stderr line per finding with the draft's line and the code, `refused`, exit 1; a hint does not refuse. `--dry-run` prints `would-create` and writes nothing |
| `path <area>/<slug> [--format=text\|json]` | the XP overview of an open learning path (`path_stats`): points (all, open, learned, seen, dropped, without XP), XP (in all, earned, open), the optional points apart, one line per stage (a root of `## Lernpunkte`), one per level with the point at which it is reached when the points are learned in order, and the points without XP |
| `path <area>/<slug> --schedule [--write]` | the table of `## Zeitplan` made from the points with `{h=…}` (`path_schedule`); `--write` puts it between `<!-- GENERATED:schedule start/end -->` |
| `milestone-new <area> <title> [--due --includes --close --status --summary --slug]` | create a milestone under `ROADMAP/milestones/` (`milestones.new`); the members must exist in this vault |
| `milestones [<area>] [--format=tsv\|json]` | the milestones: id, status, due, members done/all (and `overdue`), title |
| `plan-new <area> <title> [--slug --areas --target --phases --gate --summary --template=learning]` | create a plan file under `ROADMAP/plans/`; `--template=learning` writes the sections of a learning plan and proposes the stages `orientieren, grundlagen, vertiefen, anwenden, festigen` (stages given win). `paths.new` takes the same template: goal and competence level, access, schedule, sources (with the column `Geprüft`: the date a source was opened, or `ungeprüft`), `## Lernpunkte` (its hints name the stages `orientieren` … `festigen` as top points and the literature group with its line `Fehlt im Bestand`), `## Level` (a commented example; optional), self-check, open questions, repetition, `## Ergebnis schreiben` |
| `project-new <area> <title> [options as plan-new]` | create a project file under `ROADMAP/projects/` (`plans.new` with `kind = "project"`, the operation `project_new` of `tasks-ops/1`); plans join it with `project=<id>`. For `plan-new`, `project-new` and `path-new` the slug is `--slug` or the title, cut at a word boundary: whole words of the title as long as they fit (a hyphenated word like `Web-Variante` is one), never inside a word |
| `migrate-actor [area] [--write]` | propose `actor=me` for tasks that wait for you (status decision, tag needs-user), leave the rest empty; dry run unless `--write` |
| `attach <area>/<slug> <file> [--name=n] [--no-index]` | copy a file to `<slug>/assets/` (a plain task becomes a folder task), print the Markdown link |
| `attach <area>/<slug> --clipboard\|--latest[=<folder>] [--name=n] [--no-index]` | the same for the image on the clipboard (PNG) or the newest image of the screenshot folder(s) (`attach.screenshot_dirs`) modified within `attach.max_age_s` (300 s); named `<slug>-<date>-<HHMM>.<ext>`, a taken name gets `-2`; older: an error that names the file, nothing guessed |
| `folderize <area>/<slug> [--no-index]` | turn a plain task file into a folder task |
| `set <area>/<slug> key=value ... [--no-index]` | change frontmatter; an empty value removes the key. `waits_for=<key>` parks the task with that reason, a status other than `parked` drops it |
| `waits [area] [--format=tsv\|json]` | what the parked tasks wait for: `<key>\t<count>\t<areas>` per `waits_for` key (most tasks first), then `parked without a reason: N` and `parked: N`; `json`: the `tasks.waits` document |
| `release <key> [--dry-run] [--no-index]` | every parked task with `waits_for: <key>` gets `status: open` and loses the key (`released\t<id>` each, `would-release\t<id>` in a dry run); exit 1 when no task waits for the key or one could not be written |
| `done <area>/<slug> [--commits=repo@sha,...] [--done-in=text] [--date=YYYY-MM-DD] [--no-index]` | finish and move to `Backlog/` |
| `check [area]` | rule check |
| `check --sources [file/dir] [--write] [--timeout=<s>]` | ask the web links of the `## Quellen` table of a learning path (all open paths without an argument): HEAD with a time limit (default 8 s), GET when the server refuses HEAD. Told apart: `dead` (404, 410), `blocked` (401, 403, 429: the server shuts out programs, so neither dead nor checkable), `redirected`, `error` (other 4xx/5xx), `unreachable` (no answer). Exit 1 only for a dead link. `--write` puts date and answer into the column `Geprüft` of each row it asked about (`erreichbar 2026-11-22`, `abweisend, nicht prüfbar (403) ...`, `tot (404) ...`, `keine Antwort (Zeitlimit) ...`). Needs the network and `curl`, so it runs only on this flag: never in `check`, `ci` or the hook. Local links stay with `path-link-missing` |
| `relink [area] [--dry-run]` | mend the dead relative links to `.md` files once (`tasks_nvim.relink.repair`): one line per link (`relinked` / `would-relink`, `ambiguous` with the candidates, `unresolved`), then a summary; exit 1 when a file could not be written |
| `ci [--strict] [--no-lint] [--md-lint=<file>]` | the CI gate: check + `index --check` + md_lint of the generated indexes (see above) |
| `template [--title --kind --prio --effort --tags --lang=de\|en]` | print the task template |
| `areas [--format=names\|tsv\|json]` | the vault's areas (names, name and open count, or the `tasks.areas` document) |
| `call <method> [--params=<json>|-] [--pretty]` | the machine contract ([CONTRACT.md](CONTRACT.md)): `hello`, `snapshot`, `list`, `task`, `next`, `areas`, `done_preview`, and `ops`, the write door (the JSON is the whole request; `-` reads it from stdin; exit `1` when any operation failed); the document on stdout, exit `0` for an answer, `2` for `invalid_argument`, `1` for any other error (the error is a `tasks.error` document on stdout too) |
| `show <id> [--format=json\|text]` / `plans [area]` | one task with its body and steps (`tasks.task`), the plan files of the vault |
| `--capabilities` | the `tasks.hello` document (`call hello`) |
| `export [--top=N] [--no-links]` | all-areas overview as Markdown on stdout (never written to a file) |

Global options (before or after the command): `--vault=<dir>`,
`--today=YYYY-MM-DD`; both need a value (an empty `--vault=`, say from an unset shell
variable, is a usage error, not "the default vault"). Exit codes: `0` success, `1` a finding
/ stale index in `--check` / a failed operation, `2` a usage error. Errors go to stderr.
Terminal control characters in what is printed (ESC, other C0 controls, DEL, a lone CR, the
8-bit C1 range) come out as `?`: a task title is read from a file anyone may have edited.
Tab and newline are the output format and stay.

The vault is `--vault=<dir>`, else `$TASKS_VAULT` (no built-in default path); `$TASKS_EXTRA_AREAS` names
extra areas. Area groups come from `<vault>/area-groups.json` (no environment variable: the file is shared). lib.nvim is looked up in `$LIB_NVIM_DIR`, `$LIB_NVIM_PATH`, `$REPOS_DIR/lib.nvim`,
`.deps/lib.nvim`, a sibling checkout, then lazy.nvim's data folder.

## Limits and what is refused

A vault is data that other people and tools write, so the engine is strict about what it will load:

- `fsio.read` loads a regular file of at most `fsio.MAX_READ_BYTES` (2 MiB); a directory, a FIFO, a
  `/dev/zero` symlink or a bigger file is `nil, err`. A task file like that is an invalid task (`unreadable`),
  not a stall. A Backlog README that cannot be read stops `done` instead of being treated as missing.
- A link is not followed: a task file that is a symbolic link or a junction is not read (`symlink-task`), a folder
  of the vault whose real path leaves the vault (`vault.leaves`) is not scanned and is reported, and a folder of the
  vault root that is a link is no area. A vault that itself lies below a link is fine. A task file that points
  elsewhere would otherwise be read, and written, as if it lived in the vault. See [CONTRACT.md](CONTRACT.md).
- A frontmatter line, a title or a summary is never matched with a pattern that backtracks on whitespace or
  backslashes; table cells are escaped in one linear pass (`fsio.md_cell`). The checkbox line of `## Plan`, the asset
  links of a folder task and the marker lines of a document are read with linear scans too.
- A title is clipped in the generated index and the Backlog README row (200 characters), the blockers of a task in an
  index cell are counted after five: a generated file stays far below the read limit.
- Filter options with no value (`--status=`) and a `--today` that is no date are usage errors, not filters
  that match nothing.
- The text the engine generates is German, the language of the vault it was written for: the `TASKS.md` table
  headings always, the headings of a new task's body unless `--lang=en` / `lang = "en"` is given. It is a data
  format (the committed indexes are compared byte for byte), so the index text is not translated per session.
  Messages, commands and docs are English.
- `done` never removes a finished copy it did not create, and re-reads the task right before removing the
  original; the dashboard re-reads a task before advancing `s` / `p`. `plans.close` follows the same rule: a failing
  step puts back what THIS run changed (never a finished copy another run created, never the README over another
  run's row), a half state left by a killed close is resumed, and a failed put-back of the plan file is named
  (`rollback incomplete: ...`).
- Writers that read-modify-write a shared file go through `fsio.with_lock` (a hidden `.<name>.lock` next to it,
  created exclusively, taken over after 10 s): the Backlog README row of `done` and `plans.close` is added to the text
  on disk NOW (`mutate.readme_update`), and `mutate.set` rewrites the frontmatter under the lock, so two processes
  (an agent's CLI and the dashboard) do not drop each other's change. It serialises tasks.nvim writers; an editor with
  the file open is not one of them. A lock that fails says why in a third value: `locked` (another process holds it
  right now, asking again can help), `lock_stuck` (older than the takeover age and not deletable, or a folder or link
  where the lock file should be: it names the lock to remove by hand) or `io`.
- `mutate.set` can be a compare-and-set: `if_match` (the `etag` of the task file the caller read) and `expect`
  (`{ key, value }`, one key must still have this value) are checked against the text read UNDER the lock. A
  difference is `nil, message, { code = "conflict", id, key?, expected, actual }` and nothing is written; a change of
  another key made meanwhile is kept. The answer carries `etag_before`, `etag_after` and `before` (the old values of
  the patched keys, `REMOVE` for a key the file did not have: the inverse patch of an undo). `batch.set_many` uses the
  same check for its `expect`, so the window between looking and writing is closed. A task file that is a link is not
  written through (`code = "forbidden"`).
- A document the user names (`--write=<file>`, `chain.marker_docs`) is a literal path (`fsio.doc_path`: `~` and
  `$VAR` expanded, `[1]` no wildcard) and a symlink there is written through (`write_atomic(..., { follow_symlinks })`);
  files the vault owns are replaced, never followed.
- Ids of plans, open tasks and Backlog files are ONE namespace per area (a finished plan lands in `Backlog/FEATURES`
  and would read as a finished task of that id). `scan.finished_lookup` answers "is this id finished" from one listing
  per area; `find_done` stays for the single lookup.

## Tests

Specs live in `TESTS/` and run against a temporary fixture vault, never
against the real one:

```sh
scripts/test.sh                       # all
scripts/test.sh --file tasks_mutate   # one
```

One spec per module (`tasks_<module>_spec.lua`) plus the CLI and CI end-to-end specs; the shared helper is
`TESTS/harness.lua`, the fixture vault `TESTS/fixture.lua`.
