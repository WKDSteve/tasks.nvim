-- TESTS/sheets/features.lua -- the functionalities of tasks.nvim that start a process (directly, through lib.nvim or
-- through another plugin), read by testing.nvim (`testing perf`, `testing sheets report`). A feature sheet names its
-- entry with `feature = "<id>"`; an entry without a sheet says why with `perf`.
return {
  {
    id = "tasks.stale-refs",
    title = "--stale=refs: the open tasks whose refs changed since they were updated, dated by git (list in the background, plan while it runs)",
    surface = {
      "command:Tasks list --stale=refs",
      "command:Tasks plan --stale=refs",
      "cli:tasks list --stale-refs",
      "config:staleness",
    },
    docs = "docs/COMMANDS.md",
  },
  {
    id = "tasks.vault-clipboard",
    title = ":TasksVault clipboard and cdx copy a path or a prompt to the system clipboard (the + register, else the program of the platform)",
    surface = { "command:TasksVault clipboard", "command:TasksVault cdx" },
    docs = "docs/COMMANDS.md",
  },
  {
    id = "tasks.code-ref",
    title = ":'<,'>Tasks new writes the code-ref/1 block of the marked code into the task; a private area asks before the excerpt",
    surface = { "command:Tasks new range" },
    docs = "docs/COMMANDS.md",
  },
  {
    id = "tasks.attach-clipboard",
    title = ":Tasks attach <id> from=clipboard saves the image on the system clipboard into the task's assets",
    surface = { "command:Tasks attach from=clipboard" },
    docs = "docs/COMMANDS.md",
  },
  {
    id = "tasks.cli-index-staged",
    title = "tasks index <area> --staged builds the index from git's staging area and stages it",
    surface = { "cli:tasks index --staged" },
    docs = "docs/ENGINE.md",
  },
  {
    id = "tasks.cli-history-backfill",
    title = "tasks history backfill fills the history rows of past days from the vault's git history",
    surface = { "cli:tasks history backfill" },
    docs = "docs/ENGINE.md",
  },
  {
    id = "tasks.cli-ci",
    title = "tasks ci: the gate (rules, fresh indexes) and the Markdown linter over the generated indexes in a child Neovim",
    surface = { "cli:tasks ci", "script:scripts/tasks-ci.lua" },
    docs = "docs/ENGINE.md",
  },
  {
    id = "tasks.meetings",
    title = ":Tasks meeting new|open|list|close: meeting notes through the write door, whose documents carry the engine's commit",
    surface = { "command:Tasks meeting" },
    docs = "docs/COMMANDS.md",
  },
  {
    id = "tasks.learning-tree",
    title = ":Tasks learn|point|promote|unpromote: the learning tree in the buffer, its marks, progress, folds and images",
    surface = {
      "command:Tasks learn",
      "command:Tasks point",
      "command:Tasks promote",
      "command:Tasks unpromote",
    },
    docs = "docs/COMMANDS.md",
  },
  {
    id = "tasks.preview",
    title = ":Tasks preview <id> and :Tasks list --to=mdview show the task or the list rendered in the browser",
    surface = { "command:Tasks preview", "command:Tasks list --to=mdview" },
    perf = "manual:mdview.nvim starts its server and opens a browser window",
  },
  {
    id = "tasks.vault-search",
    title = ":TasksVault find and grep open the picker of pickers.nvim rooted at a folder of the vault",
    surface = { "command:TasksVault find", "command:TasksVault grep" },
    perf = "skip:the search process (rg) is pickers.nvim's, measured by its own sheets; tasks.nvim only hands over the folder",
  },
}
