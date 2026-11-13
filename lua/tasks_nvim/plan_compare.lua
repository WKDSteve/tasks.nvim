---@module 'tasks_nvim.plan_compare'
---@brief The figures that compare open plans side by side: tasks, effort, the rest of the critical path, the pace.
---@description
--- One row per open plan file, from the open tasks (as the plan sees them) and the finished items of the Backlogs:
---
--- - **tasks**: open and finished members, the open ones by readiness state (the states of the vault's plan).
--- - **effort**: the open effort in days (with the range of the sizes) and the finished one; how many open tasks carry
---   no effort (without it the sum looks more exact than it is).
--- - **path**: the critical path of the plan's open tasks alone (`plan.build` over the members: a blocker outside the
---   plan is external and takes no part), in days, and how many tasks on it have no effort.
--- - **pace**: the members finished in each of the last `WEEKS` weeks (oldest first, the last week ends today), and from
---   it a range of weeks the open tasks would still take: `low` at the pace of the best of those weeks, `high` at their
---   average. No range when nothing was finished in those weeks or nothing is open: a range from nothing would be a
---   guess. It counts tasks, not their effort.
--- - **phase_now**: the first stage of `phase_order` that still has an open task.
--- - **value** and **prio**: what the open tasks are worth (the sum and the average of their `value`, and how many
---   carry none) and the best `prio` among them (1 is best). Absent average and prio when no open task has one.
--- - **target_due**: the `due` of the plan's target task while that task is open, `due_in_days` from today (negative
---   when it has passed) and `forecast_late`: the slow end of the forecast (`forecast_weeks.high`) lies after that
---   day. Only with both a due day and a forecast: without a pace there is nothing to compare the day with.
---
--- Pure given its inputs: the caller reads the vault (`contract.plan_compare`).
--- Not its job: sorting or choosing plans for a page (a client does that), the plan of one plan (`plan`).

local model = require("tasks_nvim.model")
local plan = require("tasks_nvim.plan")

local M = {}

---How many weeks the pace looks back.
M.WEEKS = 4

---The readiness states a row counts (those of the vault's plan, as in the snapshot's summary).
local STATES =
  { ready = true, decision = true, waiting = true, stuck = true, freed = true, parked = true }

---@param n number
---@return number
local function round2(n)
  return math.floor(n * 100 + 0.5) / 100
end

---@class Tasks.PlanCompareRow
---@field id string
---@field title string
---@field status? string
---@field project? string
---@field stages integer
---@field phase_now? string
---@field tasks { open: integer, done: integer, ready: integer, decision: integer, waiting: integer, stuck: integer, freed: integer, parked: integer }
---@field progress number                 # done / (open + done), 0 when the plan has no tasks; two decimals.
---@field effort { open_days: number, open_low: number, open_high: number, done_days: number, open_without: integer }
---@field path { days: number, unknown_effort: integer }
---@field last_done? string               # The newest day a member was finished.
---@field weekly_done integer[]           # `WEEKS` counts, oldest first.
---@field forecast_weeks? { low: integer, high: integer }
---@field areas string[]                  # The areas the plan names.
---@field value { sum: integer, avg?: number, without: integer }   # Over the open tasks; `avg` over those that carry a value, two decimals.
---@field prio? integer                   # The best (lowest) prio of the open tasks.
---@field target? string                  # The plan's target task (an id).
---@field target_due? string              # Its `due`, while it is open.
---@field due_in_days? integer            # From today to `target_due`; negative when it has passed.
---@field forecast_late? boolean          # `forecast_weeks.high` weeks from today end after `target_due`.

---The rows for `files` (open plan files), in their order.
---@param files Tasks.PlanFile[]
---@param ctx { open: Tasks.Task[], nodes: table<string, { state?: string }>, index: Tasks.PlanIndex, finished: Tasks.Task[], today: string, is_finished_plan: fun(item: Tasks.Task): boolean }
---@return Tasks.PlanCompareRow[]
function M.rows(files, ctx)
  local open_of, done_of = {}, {}
  for _, t in ipairs(ctx.open) do
    if t.plan then
      open_of[t.plan] = open_of[t.plan] or {}
      table.insert(open_of[t.plan], t)
    end
  end
  for _, item in ipairs(ctx.finished) do
    if item.plan and not ctx.is_finished_plan(item) then
      done_of[item.plan] = done_of[item.plan] or {}
      table.insert(done_of[item.plan], item)
    end
  end
  local due_of = {}
  for _, t in ipairs(ctx.open) do
    due_of[t.id] = t.due
  end
  local out = {}
  for _, f in ipairs(files) do
    local open, done = open_of[f.id] or {}, done_of[f.id] or {}
    local tasks = {
      open = #open,
      done = #done,
      ready = 0,
      decision = 0,
      waiting = 0,
      stuck = 0,
      freed = 0,
      parked = 0,
    }
    local effort = { open_days = 0, open_low = 0, open_high = 0, done_days = 0, open_without = 0 }
    local sums = require("tasks_nvim.estimate").rollup(open)
    effort.open_days = round2(sums.days)
    effort.open_low = round2(sums.range.low)
    effort.open_high = round2(sums.range.high)
    effort.open_without = sums.n_without_effort
    local open_phases = {}
    local value = { sum = 0, without = 0 }
    local valued, prio = 0, nil
    for _, t in ipairs(open) do
      local node = ctx.nodes[t.id]
      local state = node and node.state
      if state and STATES[state] then
        tasks[state] = tasks[state] + 1
      end
      if t.phase then
        open_phases[t.phase] = true
      end
      if t.value then
        value.sum = value.sum + t.value
        valued = valued + 1
      else
        value.without = value.without + 1
      end
      if t.prio and (prio == nil or t.prio < prio) then
        prio = t.prio
      end
    end
    if valued > 0 then
      value.avg = round2(value.sum / valued)
    end
    local done_days, last_done = 0, nil
    local weekly = {}
    for i = 1, M.WEEKS do
      weekly[i] = 0
    end
    for _, item in ipairs(done) do
      done_days = done_days + (model.effort_days(item.effort) or 0)
      local date = model.done_date(item.path)
      if date then
        if last_done == nil or date > last_done then
          last_done = date
        end
        local age = model.days_between(date, ctx.today)
        if age and age >= 0 and age < 7 * M.WEEKS then
          local bucket = M.WEEKS - math.floor(age / 7)
          weekly[bucket] = weekly[bucket] + 1
        end
      end
    end
    effort.done_days = round2(done_days)
    local best, sum = 0, 0
    for _, n in ipairs(weekly) do
      best = math.max(best, n)
      sum = sum + n
    end
    local forecast
    if #open > 0 and best > 0 then
      forecast = {
        low = math.ceil(#open / best),
        high = math.ceil(#open / (sum / M.WEEKS)),
      }
    end
    local phase_now
    for _, ph in ipairs(f.phase_order or {}) do
      if open_phases[ph] then
        phase_now = ph
        break
      end
    end
    local target_due = f.target and due_of[f.target] or nil
    local due_in_days = target_due and model.days_between(ctx.today, target_due) or nil
    local forecast_late
    if due_in_days and forecast then
      forecast_late = forecast.high * 7 > due_in_days
    end
    local critical = plan.build(open, ctx.index).critical
    local total = #open + #done
    out[#out + 1] = {
      id = f.id,
      title = f.title,
      status = f.status,
      project = f.project,
      stages = #(f.phase_order or {}),
      phase_now = phase_now,
      tasks = tasks,
      progress = total > 0 and round2(#done / total) or 0,
      effort = effort,
      path = { days = round2(critical.days), unknown_effort = critical.unknown },
      last_done = last_done,
      weekly_done = weekly,
      forecast_weeks = forecast,
      areas = f.areas or {},
      value = value,
      prio = prio,
      target = f.target,
      target_due = due_in_days and target_due or nil,
      due_in_days = due_in_days,
      forecast_late = forecast_late,
    }
  end
  return out
end

return M
