---@module 'tasks_nvim.config.DEFAULTS'
---@brief Plugin defaults.
---@description
--- Deliberately no vault: tasks.nvim has no opinion about where your vault lives. Without `vault` the engine
--- reads `$TASKS_VAULT` and otherwise reports "vault not found" instead of guessing a path.

---@class Tasks.DashboardConfig
---@field watch boolean        Refresh the dashboard when a task or Backlog file changes (file watchers).
---@field debounce_ms integer  Quiet period after a change before the list is rescanned.
---@field backend "auto"|"snacks"|"kit"|"select"  The picker behind `:Tasks list`: `snacks` (snacks.nvim), `kit` (lib.nvim's own picker, no snacks needed; its keys are the Alt chords of `keys.dashboard_input`), `select` (a plain `vim.ui.select` list), `auto` = snacks when installed, else kit.

---@class Tasks.StalenessConfig
---@field git_timeout_ms integer  One `git log` call is killed after this long (`--stale=refs`).
---@field budget_ms integer       All git calls of one `--stale=refs` run share this much time; the rest falls back to mtimes.
---@field repo_bases string[]     Folders that hold the repos by name (`<base>/<area>`); empty: derived from the vault and `$REPOS_DIR`.

---@class Tasks.NextConfig
---@field popup boolean     After finishing a task: offer the next one to open (a small dialog; headless sessions get a message).
---@field cdx_hint boolean  Name the ready tasks written `cdx` apart ("an AI session could take ..."), never as your next task.

---@class Tasks.StepsConfig
---@field ask_finish boolean  In a task buffer: when the LAST open step of `## Plan` is ticked, ask whether to finish the task (off by default: it adds an autocommand on task buffers).

---@class Tasks.RemindersConfig
---@field on_start boolean  One line at startup when reminders (`remind:`) are due (a moment later, once per session, only with a UI; `false` turns it off).

---@class Tasks.AttachConfig
---@field screenshot_dirs string[]  Folders `attach --latest` looks into (empty: the usual screenshot folders of the system, see `tasks_nvim.attach_source`).
---@field max_age_s integer         `attach --latest` only takes a file modified within this many seconds (default 300), otherwise it asks.

---@class Tasks.CompletionConfig
---@field finished boolean|integer  Which finished tasks `<Tab>` offers for `:Tasks open` and `preview`: `true` all of them, `false` none, a number only those finished in the last N days (a task of any age can still be typed in full).

---@class Tasks.QuickWinsConfig
---@field min_value integer   A task is a quick win with at least this value (1-5) ...
---@field max_effort string   ... and at most this effort (`XS`..`XL` or days like `0.5d`); both must be written on the task.

---@class Tasks.ChainConfig
---@field marker_docs string[]  Documents whose `<!-- GENERATED:plan scope=... -->` blocks are refreshed after a task is finished. Only these files are ever touched (nothing is scanned); empty by default. The headless CLI has no `setup`: `$TASKS_MARKER_DOCS` (comma separated) names them there.

---@class Tasks.CiConfig
---@field lint_timeout_ms integer  The vault's `md_lint.lua` is killed after this long (`ci`).
---@field trust_vault_lint boolean  Allow `ci` to run `<vault>/TOOLS/scripts/md_lint.lua` (code from the vault itself).

---Key maps: an action name to a key, or `false` to switch that action's key off. An action that is not named
---keeps its default key.
---@alias Tasks.KeyMap table<string, string|false>

---@class Tasks.CheckConfig
---@field ui_words_off string[]  Vaults (their names in `vaults`, or their folders) where `check` gives no hint for a UI word in a title (`ui-word-without-ux`).

---@class Tasks.KeysConfig
---@field dashboard Tasks.KeyMap        Keys in the dashboard list window.
---@field dashboard_input Tasks.KeyMap  Keys in the dashboard input window (normal and insert mode).
---@field form Tasks.KeyMap             Buffer-local keys of the `:Tasks new` form.
---@field learning Tasks.KeyMap         Buffer-local keys of the learning tree view (`:Tasks learn`): `cycle`, `promote`, `unpromote`, `image`, `follow`, `xp`. None by default.

---@class Tasks.Opts
---@field vault string|nil          Vault folder (one folder per area). `nil`: `$TASKS_VAULT` is read.
---@field vaults table<string, string>  Named vaults (`{ main = "<dir>", other = "<dir>" }`). `vault` may then be one of the names (without it the first name, sorted, is active); `:TasksVault switch <name>` changes the active one for the session.
---@field vault_rules Tasks.VaultRule[]  Pick the vault by the working directory at `setup()`: `{ { match = "~/work", vault = "work" } }`; the first rule whose folder holds the cwd wins over `vault`, a rule for an unnamed vault is skipped.
---@field extra_areas string[]      Folders that are areas although they hold neither `ROADMAP/` nor `Backlog/`.
---@field links "plain"|"wikilink"   How `set`, `new`, the dashboard and the moves write a task or plan reference (`blocked_by`, `after`, `plan`): `plain` ids (`<area>/<slug>`) or Obsidian wikilinks (`"[[<slug>]]"`, to a finished task its file name `"[[YYYY-MM-DD_<slug>]]"`, the vault path with the id as alias when the slug is in several areas). A value a file already holds keeps its form; both are always read. The headless CLI has no `setup`: `$TASKS_LINKS=wikilink` switches it there (Neovim reads it too while `setup()` names no `links`; a `links` set here wins).
---@field dashboard Tasks.DashboardConfig
---@field staleness Tasks.StalenessConfig
---@field ci Tasks.CiConfig
---@field check Tasks.CheckConfig
---@field next Tasks.NextConfig
---@field chain Tasks.ChainConfig
---@field quick_wins Tasks.QuickWinsConfig
---@field lists table<string, Tasks.ListDef>  Named lists (a filter combination plus a sort order): `{ ["my-list"] = { effort = "<=S", value = ">=4", sort = "roi" } }`. See `tasks_nvim.lists`.
---@field area_groups table<string, Tasks.AreaGroupDef>  Area groups on top of `<vault>/area-groups.json` (same shape, a group here wins by name; only inside Neovim, the headless CLI and tasks-desktop read the file): `{ nvim = { include = { "*.nvim" } } }`. A group is a filter name for `list`, `next`, `plans` and the dashboard. See `tasks_nvim.area_groups`.
---@field steps Tasks.StepsConfig
---@field sheet_run { testing_cli?: string }  `:Tasks sheet-run`: the path of testing.nvim's `scripts/testing.lua` (default: found like a dependency, `tasks_nvim.sheet_run`).
---@field reminders Tasks.RemindersConfig
---@field attach Tasks.AttachConfig
---@field completion Tasks.CompletionConfig
---@field keys Tasks.KeysConfig
---@field form Tasks.FormConfig
---@field learning Tasks.LearningConfig
---@field gamification boolean  XP per learning point, the level reached and the open rewards in the learning tree view (`:Tasks learn`), and the one quiet line when a level is reached. `false` hides all of it; the tree and its progress stay. `:Tasks xp` and `:Tasks reward` still write when called.
---@field tree boolean|Tasks.Tree.Opts  The vault in a tree view that reads `lib.nvim.tree.registry` (the own tree of filetree.nvim): a count of open tasks on the area folders, a view `tasks`, and the actions "finish" and "claim" on a task. `true`: registered, the actions in the tree's menu; `{ keys = { done = "<key>", claim = "<key>" } }`: on those keys in the tree buffer as well; `false`: nothing is registered.
---@field ai boolean|"auto"  The AI functions of the ai family (handing a task to an agent of ai-desktop or ai.nvim): `false` none at all (no command, no key, no menu entry), `true` always offered, `"auto"` only where ai.nvim or ai-desktop is found on this machine. AI does not push itself forward; `:checkhealth tasks_nvim` says what is found. See `tasks_nvim.ai`.

---@class Tasks.LearningConfig
---@field auto boolean  Attach the learning tree view (`:Tasks learn`) by itself to a learning path or a task with `## Lernpunkte` when it is shown (group `TasksLearnAuto`). Off by default.

---@class Tasks.FormConfig
---@field mode "float"|"split"|"vsplit"|"current"  Window of the `:Tasks new` form: a centered float, a split below, a vertical split or the current window. `:Tasks new mode=...` overrides it for one call.

---@type Tasks.Opts
return {
  vault = nil,
  vaults = {},
  vault_rules = {},
  extra_areas = {},
  links = "plain",
  dashboard = { watch = true, debounce_ms = 250, backend = "auto" },
  staleness = { git_timeout_ms = 20000, budget_ms = 30000, repo_bases = {} },
  ci = { lint_timeout_ms = 120000, trust_vault_lint = false },
  check = { ui_words_off = {} },
  next = { popup = true, cdx_hint = true },
  chain = { marker_docs = {} },
  quick_wins = { min_value = 4, max_effort = "S" },
  lists = {},
  area_groups = {},
  steps = { ask_finish = false },
  sheet_run = { testing_cli = nil },
  reminders = { on_start = false },
  attach = { screenshot_dirs = {}, max_age_s = 300 },
  completion = { finished = true },
  form = { mode = "float" },
  learning = { auto = false },
  gamification = true,
  tree = true,
  ai = "auto",
  keys = {
    dashboard = {
      status = "s",
      prio = "p",
      done = "D",
      filter = "f",
      lists = "gl",
      sort = "o",
      export = "e",
      rescan = "r",
      attach = "ga",
      agent = "gh",
      agent_run = "gH",
      backlog = "gb",
      roadmap = "gr",
      preview = "gp",
      help = "g?",
      view = "v",
      assign = "P",
      move_down = "J",
      move_up = "K",
    },
    dashboard_input = {
      status = "<M-s>",
      prio = "<M-p>",
      done = "<M-d>",
      filter = "<M-f>",
      lists = "<M-l>",
      sort = "<M-o>",
      export = "<M-e>",
      rescan = "<M-r>",
      attach = "<M-i>",
      agent = "<M-h>",
      agent_run = "<M-H>",
      backlog = "<M-b>",
      roadmap = "<M-m>",
      preview = "<M-v>",
      help = "<M-?>",
      view = "<M-g>",
      assign = "<M-a>",
      move_down = "<M-j>",
      move_up = "<M-k>",
    },
    form = {
      tick_space = "<Space>",
      tick_enter = "<CR>",
      submit = "<C-s>",
      cancel = "q",
      cancel_ctrl = "<C-q>",
      help = "g?",
      icon = "<C-e>",
    },
    learning = {
      cycle = false,
      promote = false,
      unpromote = false,
      image = false,
      follow = false,
      xp = false,
    },
  },
}
