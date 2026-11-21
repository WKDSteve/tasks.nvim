---@module 'tasks_nvim.path_stats'
---@brief The XP overview of a learning path: points, XP in all and per stage, points without XP, and for each level
---the point at which it would be reached when the points are learned in their order.
---@description
--- A stage is a root node of `## Lernpunkte` (`Stufe 0 · Orientieren`); a root without children is a stage of one
--- point. A point is a leaf. The XP of a leaf is the one `lernbaum` counts: the `xp:` of its task when it was promoted
--- (`paths.with_xp`), else its own `{xp=N}`.
---
--- The forecast walks the leaves in document order (the order of learning) and counts every one as learned in full;
--- a dropped leaf is left out, as it is left out of the sum. A level in XP is reached at the first point where the sum
--- comes to its threshold; one in percent where the sum comes to that share of the possible XP (a tree without any XP
--- counts its points instead, as `lernlevel.evaluate` does); the line for the whole path at the last point that is not
--- dropped. A threshold of 0 is reached before the first point (`at_start`); one the path cannot reach has no `at`.
---
--- Optional points (`{optional}` in `lernbaum`) stand apart (`optional`): the counts, the XP and the forecast hold the
--- other points only; a stage that is optional as a whole says so (`optional = true`) and counts its own points.
---
--- Pure Lua, no I/O: the caller reads the path (`paths.find`).

local M = {}

---@class Tasks.PathStatsPoint
---@field index integer   # 1-based among the points that count (not dropped).
---@field line integer
---@field key? string
---@field label string
---@field stage integer   # The number of its stage, 1-based.

---@class Tasks.PathStatsStage
---@field number integer
---@field line integer
---@field key? string
---@field label string
---@field points integer        # Leaves, dropped ones included.
---@field open integer
---@field xp integer            # The XP of its leaves that are not dropped.
---@field earned integer
---@field without_xp integer
---@field optional? boolean     # The stage is optional as a whole; else its numbers leave optional points out.

---@class Tasks.PathStatsLevel
---@field ref string             # `"1"`, `"2"`, … or `"done"`.
---@field number? integer
---@field kind "xp"|"percent"|"done"
---@field threshold? integer
---@field name? string
---@field needed? integer        # The XP (or, without XP, the points) the level needs, whole (a percent rounded up);
---                               nil for the path line.
---@field reached boolean        # Reached now (`lernlevel.evaluate`).
---@field at_start? boolean      # Reached before the first point (a threshold of 0).
---@field at? Tasks.PathStatsPoint  # The point at which it would be reached; nil when it cannot be.

---@class Tasks.PathStats
---@field has_xp boolean
---@field points { total: integer, open: integer, learned: integer, seen: integer, dropped: integer, blocked: integer, without_xp: integer, counted: integer }
---@field xp { total: integer, earned: integer, open: integer }
---@field optional? { points: integer, open: integer, learned: integer, seen: integer, dropped: integer, xp: integer, earned: integer }  # nil: no optional points.
---@field stages Tasks.PathStatsStage[]
---@field without_xp { line: integer, key?: string, label: string, stage: integer }[]
---@field levels Tasks.PathStatsLevel[]
---@field level integer          # The level reached now (0: none).

---The leaves below a node (the node itself when it has none), in document order.
---@param node Tasks.LernNode
---@param out Tasks.LernNode[]
local function leaves(node, out)
  if #node.children == 0 then
    out[#out + 1] = node
    return
  end
  for _, c in ipairs(node.children) do
    leaves(c, out)
  end
end

---The overview of a path's tree and levels.
---@param tree Tasks.LernTree     # `lernbaum.parse`, with the task XP given (`paths.with_xp`).
---@param lv? Tasks.Levels        # `lernlevel.parse`; nil: no levels.
---@param state? Tasks.LevelState # `lernlevel.evaluate`; nil: computed when `lv` is given.
---@return Tasks.PathStats
function M.compute(tree, lv, state)
  local p, x = tree.progress, tree.xp
  -- XP when the points that count carry any (a tree whose XP are all optional counts points, as `lernlevel` does)
  local by_xp = x.points > 0
  ---@type Tasks.PathStats
  local out = {
    has_xp = by_xp,
    points = {
      total = p.total,
      open = p.open,
      learned = p.learned,
      seen = p.seen,
      dropped = p.dropped,
      blocked = p.blocked,
      without_xp = x.missing,
      counted = p.total - p.dropped,
    },
    xp = { total = x.possible, earned = x.earned, open = x.open },
    stages = {},
    without_xp = {},
    levels = {},
    level = 0,
  }
  local op = tree.optional and tree.optional.progress
  if op and op.total > 0 then
    local ox = tree.optional.xp
    out.optional = {
      points = op.total,
      open = op.open,
      learned = op.learned,
      seen = op.seen,
      dropped = op.dropped,
      xp = ox.possible,
      earned = ox.earned,
    }
  end

  -- the points in the order of learning, each with its stage
  ---@type { node: Tasks.LernNode, stage: integer }[]
  local order = {}
  for i, root in ipairs(tree.roots) do
    local whole = root.in_optional == true
    local rp, xp = root.progress, root.xp_progress
    if not whole and root.opt_progress and root.opt_progress.total > 0 then
      rp, xp = {}, {}
      for k, v in pairs(root.progress) do
        rp[k] = v - root.opt_progress[k]
      end
      for k, v in pairs(root.xp_progress) do
        xp[k] = v - root.opt_xp[k]
      end
    end
    out.stages[#out.stages + 1] = {
      number = i,
      line = root.line,
      key = root.key,
      label = root.label,
      points = rp.total,
      open = rp.open,
      xp = xp.possible,
      earned = xp.earned,
      without_xp = xp.missing,
      optional = whole or nil,
    }
    local list = {}
    leaves(root, list)
    for _, leaf in ipairs(list) do
      if leaf.state ~= "dropped" and not leaf.in_optional then
        order[#order + 1] = { node = leaf, stage = i }
        if not leaf.xp then
          out.without_xp[#out.without_xp + 1] =
            { line = leaf.line, key = leaf.key, label = leaf.label, stage = i }
        end
      end
    end
  end

  if not lv then
    return out
  end
  state = state or require("tasks_nvim.lernlevel").evaluate(lv, tree)
  out.level = state.level or 0

  -- the running sum after each point: XP, or points when the tree has no XP
  local units = by_xp and x.possible or #order
  ---@param i integer
  ---@return Tasks.PathStatsPoint
  local function point(i)
    local o = order[i]
    return { index = i, line = o.node.line, key = o.node.key, label = o.node.label, stage = o.stage }
  end
  ---@param reached_at fun(sum: number): boolean
  ---@return boolean at_start
  ---@return Tasks.PathStatsPoint|nil at
  local function first(reached_at)
    if reached_at(0) then
      return true, nil
    end
    local sum = 0
    for i, o in ipairs(order) do
      sum = sum + (by_xp and (o.node.xp or 0) or 1)
      if reached_at(sum) then
        return false, point(i)
      end
    end
    return false, nil
  end

  for _, l in ipairs(lv.levels) do
    ---@type Tasks.PathStatsLevel
    local row = {
      ref = l.ref,
      number = l.number,
      kind = l.kind,
      threshold = l.threshold,
      name = l.name,
      reached = state.reached[l.ref] == true,
    }
    local reached_at
    if l.kind == "xp" then
      -- a level in XP needs XP of the points that count: without any it is not forecast (the optional XP are no order)
      row.needed = l.threshold
      if by_xp then
        reached_at = function(sum)
          return sum >= l.threshold
        end
      end
    elseif units > 0 then
      -- `evaluate`: floor(sum * 100 / units) >= threshold, which is sum * 100 >= threshold * units
      -- whole XP (or points), rounded up: the level is there once the threshold is full, and the sum is whole
      row.needed = math.ceil(l.threshold * units / 100)
      reached_at = function(sum)
        return sum * 100 >= l.threshold * units
      end
    end
    if reached_at then
      row.at_start, row.at = first(reached_at)
    end
    out.levels[#out.levels + 1] = row
  end
  if lv.final then
    out.levels[#out.levels + 1] = {
      ref = "done",
      kind = "done",
      name = lv.final.name,
      reached = state.reached.done == true,
      at = #order > 0 and point(#order) or nil,
    }
  end
  return out
end

return M
