# Bindings

## Command

`:Tasks <verb>` (a `lib.nvim` composer verb, `<Tab>` completes verbs, areas, task ids and values). No default
keymaps and no autocommands at load time (the browser preview adds a short-lived `TasksPreviewTemp` group while a temporary file exists; the learning tree view adds buffer-local ones in the group `TasksLearn` while it is on, and `learning = { auto = true }` the group `TasksLearnAuto`; a checklist buffer redraws itself on entering it, group `TasksChecklist<buf>`, gone with the buffer). Set `vim.g.tasks_nvim_no_command = true` to register your own verb from
`tasks_nvim.ui.routes` instead.

| Verb | Arguments | Does |
| --- | --- | --- |
| `list` | `[<area>\|all]` + filters (`--status= --prio= --effort= --kind= --category= --severity= --tag= --stale= --blocked`), `--sort=`, `--to=`, `--format=` | open tasks as a table, or the dashboard when nothing is delivered elsewhere |
| `index` | `[<area>] [--all] [--check]` | (re)write `ROADMAP/TASKS.md`; `--check` writes nothing |
| `new` | `[<area> [title...]] [kind= prio= effort= tags= category= severity= status=] [--folder]` | create a task (without arguments: the Markdown form) |
| `set` | `<id> key=value ...` | change frontmatter |
| `done` | `<id> [done_in= commits= date=] [--yes]` | finish after confirmation, move to `Backlog/` |
| `attach` | `<id> <file> [name=]` | copy a file into the task's `assets/` (an entry of a checklist, `_list-<list>/<slug>`, takes one too) |
| `checklist` | `[<list>]`, `new <title...>`, `add <list> <line...>` | the checklists (`_list-<slug>/`): pick or name one and it opens in a buffer of its own (keys below); make a list; add an entry (`#word` = tag) |
| `folderize` | `<id>` | turn a plain task into a folder task |
| `template` | `[--to=]` | the task file template |
| `open` | `[<id>] [--desktop\|--web]` | open the file of a task; `--desktop` / `--web` show the task alone in tasks-desktop or tasks-web (no id: the task of the buffer, else the one created last) |
| `preview` | `<id>` | browser preview through mdview.nvim |
| `folder` | `<area> [tasks\|roadmap\|backlog\|handover\|notes\|all] [--action=] [--list] [--to=]` | picker over an area folder |
| `learn` | `[toggle\|on\|off\|image\|follow]` | the learning tree view in this buffer: progress, folds, image placeholders; the image or the promoted task of the point under the cursor |
| `point` | `[next\|open\|learned\|seen\|dropped\|blocked] [reason...]` | the mark of the learning point under the cursor; `[~]` and `[-]` ask for the reason, and `[x]` on an exercise point whose `Nachweis` has no `Ergebnis` yet asks for the result |
| `promote` | `[<area>/<slug>#<key\|n>] [--area= --title= --actor= --dry-run --no-index]` | make a task of a learning point (default: the one under the cursor) and open it |
| `unpromote` | `[<area>/<slug>#<key\|n>] [--dry-run --no-index]` | take a promotion back while the task holds no work |

Details of every verb: [COMMANDS.md](COMMANDS.md).

## Dashboard keys (buffer-local, `g?` shows them)

| Key | Does |
| --- | --- |
| `<CR>` | open the file(s); counts as a visit for `--sort=frecency` |
| `<Tab>` | mark / unmark |
| `s` / `p` | advance status / prio of marked (else current) tasks |
| `D` | finish (asks first) |
| `f` | set a filter chip |
| `gl` | named lists: apply one, save the current filter and sort as one, rename or delete a saved one |
| `o` | cycle the sort |
| `e` | export marked (else all shown) tasks |
| `gp` | preview the task file in the browser |
| `r` | rescan now |
| `ga` | attach a screenshot to the task under the cursor (clipboard image, else the newest screenshot) |
| `gb` / `gr` | Backlog picker / ROADMAP of the area under the cursor |
| `v` | switch between the list and the stage view |
| `P` | give the marked (else current) tasks a plan and a stage |
| `J` / `K` | stage view: move the task down / up among its stage's tasks (sets `order`) |
| `g?` | help in a float; stays until `q` / `<Esc>` or leaving the window |

A count works on the cycling keys: `3p` advances the priority three steps, `2s` the status, `3o` the sort order. The other keys ignore a count (mark several tasks with `<Tab>` instead).

In the input window the same actions are on Alt (these shadow snacks.nvim's own `<M-d>` inspect, `<M-f>` follow,
`<M-r>` regex, `<M-m>` maximize and `<M-p>` preview toggles there; turn any of them off or move it with `keys`, below): `<M-s> <M-p> <M-d> <M-f> <M-l> <M-o> <M-e> <M-r> <M-i> <M-b> <M-m> <M-v> <M-?>` (`<M-l>` is the lists menu, `<M-i>` attaches a screenshot).

## Changing or switching off keys

```lua
require("tasks_nvim").setup({
  keys = {
    dashboard = { done = "X", preview = false },     -- list window; false: no key for that action
    dashboard_input = { sort = "<M-t>", filter = false },  -- input window (normal and insert mode)
    form = { cancel = false, submit = "<C-CR>" },    -- `:Tasks new` form
    learning = { cycle = "<localleader>x" },          -- learning tree view (none by default)
    checklist = { toggle = "<Space>", promote = false }, -- checklist buffer
  },
})
```

An action that is not named keeps its default. Dashboard actions: `status prio done filter sort export rescan
backlog roadmap preview view assign move_down move_up help`, and while the AI functions are on `agent agent_run` (`gh` / `gH`:
the task under the cursor to `:Tasks agent`, prefill / run). Form actions: `tick_space tick_enter submit cancel cancel_ctrl help icon`. Learning tree actions: `cycle promote unpromote image follow xp`. Checklist actions: `add toggle open delete promote
filter clear state refresh lists close help`. An unknown
action name is reported (and listed in `:checkhealth`), never bound. The help (`g?`) lists the default keys.

## Checklist (`:Tasks checklist`, buffer-local, `g?` shows them)

| Key | Action | Does |
| --- | --- | --- |
| `a` | `add` | add an entry; a `#word` of the line becomes a tag |
| `x` | `toggle` | tick the entry under the cursor, or open it again |
| `<CR>` | `open` | open the entry as a Markdown file |
| `D` | `delete` | delete it with its attachments (asks first) |
| `T` | `promote` | make it a task of an area (picked) |
| `f` / `F` | `filter` / `clear` | filter (`#tag since:<day> until:<day> state:open\|done\|all words`) / clear the filter |
| `s` | `state` | show all, the open or the done entries |
| `r` | `refresh` | read the files again |
| `gl` | `lists` | pick another list |
| `q` | `close` | close the list buffer |
| `g?` | `help` | the keys in a float |

No key takes a count.

## Learning tree (`:Tasks learn`, buffer-local, none by default)

The view maps no key unless `keys.learning` names one; then the key is buffer-local while the view is on:

| Action | Does |
| --- | --- |
| `cycle` | next mark of the point under the cursor: `[ ]` -> `[x]` -> `[~]` -> `[-]` -> `[ ]` (`[~]` and `[-]` ask for the reason; `[x]` on an exercise point with a `Nachweis` and no `Ergebnis` asks for the result) |
| `promote` | promote the point under the cursor to a task (`:Tasks promote`) |
| `unpromote` | take its promotion back (`:Tasks unpromote`) |
| `image` | show its image: images.nvim, else mdview.nvim's browser preview, else the path |
| `follow` | open the task it was promoted to |
| `xp` | set its XP (`:Tasks xp`): a question filled in with its own XP or a suggestion |

```lua
require("tasks_nvim").setup({
  learning = { auto = true },  -- the view by itself on learning paths and tasks with ## Lernpunkte
  keys = { learning = { cycle = "<localleader>x", promote = "<localleader>p", follow = "gd" } },
})
```

## Form (`:Tasks new` without arguments)

Buffer-local keys of the form buffer:

| Key | Does |
| --- | --- |
| `<Space>` / `<CR>` on a `- [ ]` line | tick or untick (single-choice lists keep one tick, `category` takes several) |
| `<C-s>` (normal and insert) | submit |
| `q` (normal) / `<C-q>` | cancel; asks first when text was typed |
| `g?` | help |
| `<C-e>` (normal) | pick the icon with emojis.nvim into the `Icon:` line (without it: the cursor goes there, type it) |

## Headless

`scripts/tasks.lua` and `scripts/tasks-ci.lua`; see [ENGINE.md](ENGINE.md).
