---@module 'tasks_nvim.bindings.autocmds'
---@brief Autocommands of tasks.nvim: none at load time.
---@description
--- Nothing is registered by `setup()` or `plugin/`. The dashboard refreshes through libuv `fs_event`
--- handles that live and die with its window (`tasks_nvim.ui.dash_watch`). The only autocommands are the
--- ones the browser preview makes while a temporary preview file exists (group `TasksPreviewTemp`,
--- `tasks_nvim.ui.preview`): they clean it up on buffer wipe and on `VimLeavePre`. One more is opt-in:
--- `setup({ steps = { ask_finish = true } })` registers the group `TasksStepsWatch` (`tasks_nvim.ui.steps_watch`),
--- which looks only at task files of the vault. The learning tree view (`:Tasks learn`, `tasks_nvim.ui.learn`) adds
--- buffer-local autocommands in the group `TasksLearn` while it is on, and `setup({ learning = { auto = true } })` the
--- group `TasksLearnAuto` (puts the view on paths and learning tasks when they are shown).

---@type table[]
return {}
