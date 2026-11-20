-- TESTS/tasks_learn_xp_view_spec.lua -- XP, level and rewards in the learning tree view (`tasks_nvim.ui.learn`): the XP
-- of each leaf at its line end (a promoted one with its task's), "earned / possible XP · Level n (name) · Belohnung
-- offen: ..." on the heading, `:Tasks xp` (a value, clear, the question filled in with the own XP or a suggestion,
-- refused on a parent and on a point whose task carries xp:), the one quiet line when a level is reached,
-- `:Tasks reward` (granted, undo, refused outside a path), `gamification = false` and `:checkhealth`.
-- @scans-data: the spec lists its fixture vault in the temp folder only

---@diagnostic disable: need-check-nil
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, has, lacks = H.eq, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local config = require("tasks_nvim.config")
  local learn = require("tasks_nvim.ui.learn")
  local mutate = require("tasks_nvim.mutate")
  local vault = require("tasks_nvim.vault")

  local ARROW = "\226\134\146"
  local DOT = " \194\183 "
  local A = "lib.nvim"
  local root = F.vault(H)
  vault.set_root(root)
  config.merge({})

  local told = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    told[#told + 1] = tostring(msg)
  end
  local function said()
    local all = table.concat(told, "\n")
    told = {}
    return all
  end
  local real_input = vim.ui.input
  local answer -- what the question answers (nil: cancelled)
  local asked -- the options of the last question
  vim.ui.input = function(opts, cb)
    asked = opts
    cb(answer)
  end
  local real_echo = vim.api.nvim_echo
  local echoed = {}
  vim.api.nvim_echo = function(chunks, history, opts)
    local text = {}
    for _, c in ipairs(chunks) do
      text[#text + 1] = c[1]
    end
    echoed[#echoed + 1] = table.concat(text)
    return real_echo(chunks, history, opts)
  end

  local proj = assert(mutate.new(A, { root = root, title = "XP Projekt", xp = 40 }))

  local path_file = root .. "/" .. A .. "/ROADMAP/paths/xp-lernen.md"
  H.write(
    path_file,
    table.concat({
      "---", -- 1
      "title: XP lernen", -- 2
      "status: doing", -- 3
      "updated: 2026-11-01", -- 4
      "---", -- 5
      "", -- 6
      "## Lernpunkte", -- 7
      "", -- 8
      "- [ ] Grundlagen {#g}", -- 9
      "  - [x] Syntax {xp=20}", -- 10
      "  - [ ] Tabellen {xp=30}", -- 11
      "- [ ] Projekt " .. ARROW .. " " .. proj.id .. " {xp=5}", -- 12
      "- [ ] Ohne XP", -- 13
      "", -- 14
      "## Level", -- 15
      "", -- 16
      "- [ ] 20 XP · Einsteiger · Belohnung: Eis", -- 17
      "- [ ] 60 XP · Profi · Belohnung: Kino", -- 18
      "- [ ] 200 XP · Meister", -- 19
      "", -- 20
    }, "\n")
  )

  ---@param path string
  ---@return integer buf
  local function open(path)
    vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end
  ---@param row integer
  local function at(row)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
  local function virt(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, learn.ns, 0, -1, { details = true })) do
      local text = {}
      for _, chunk in ipairs(m[4].virt_text or {}) do
        text[#text + 1] = chunk[1]
      end
      out[#out + 1] = (m[2] + 1) .. ":" .. table.concat(text)
    end
    return table.concat(out, "\n")
  end
  local function ctx(args, flags)
    return { args = args or {}, rest = {}, flags = flags or {}, kv = {} }
  end

  -- ── the view: XP per leaf, the sum, the level, the open reward ─────────────
  local buf = open(path_file)
  learn.attach(buf)
  local v = virt(buf)
  has(v, "10:  20 XP", "a leaf's own XP at its line end")
  has(v, "11:  30 XP")
  has(v, "12:  40 XP", "a promoted leaf: the xp: of its task, not its own {xp=5}")
  lacks(v, "13:", "a leaf without XP gets nothing")
  has(v, "7:  1 gelernt", "the progress stays on the heading")
  has(
    v,
    DOT .. "20 / 90 XP" .. DOT .. "Level 1 (Einsteiger)" .. DOT .. "Belohnung offen: Eis",
    "the heading: earned / possible XP, the level reached and its open reward"
  )
  eq(#echoed, 0, "the level the buffer opens with is not announced")

  -- ── :Tasks xp ──────────────────────────────────────────────────────────────
  at(11)
  learn.cmd_xp(ctx({ value = "35" }))
  has(H.read(path_file), "  - [ ] Tabellen {xp=35}\n", "a value is written on disk")
  has(virt(buf), "11:  35 XP", "and drawn after the reload")
  at(11)
  answer = "50"
  learn.cmd_xp(ctx())
  eq(asked.default, "35", "the question offers the point's own XP")
  has(H.read(path_file), "  - [ ] Tabellen {xp=50}\n")
  at(13)
  answer = nil
  learn.cmd_xp(ctx())
  eq(asked.default, "20", "without XP of its own: the engine's suggestion for a root point")
  lacks(H.read(path_file), "Ohne XP {xp", "cancelled: nothing written")
  at(13)
  learn.cmd_xp(ctx({ value = "15" }))
  has(H.read(path_file), "- [ ] Ohne XP {xp=15}\n")
  at(13)
  learn.cmd_xp(ctx({ value = "clear" }))
  has(H.read(path_file), "- [ ] Ohne XP\n", "clear removes it")
  at(13)
  learn.cmd_xp(ctx({ value = "lots" }))
  has(said(), "xp must be a whole number")
  at(9)
  learn.cmd_xp(ctx({ value = "5" }))
  has(said(), "sums the XP of its children", "a parent has no XP of its own")
  at(12)
  learn.cmd_xp(ctx({ value = "9" }))
  has(said(), "change it there", "a point whose task carries xp: is changed in the task")
  has(H.read(path_file), proj.id .. " {xp=5}", "the file as it was")

  -- the task's xp: read once per set of arrows, again after the buffer is read: a change of the task shows then
  assert(mutate.set(proj.id, { xp = 45 }, { root = root }))
  learn.refresh(buf)
  has(virt(buf), "12:  40 XP", "while typing the vault is not scanned again")
  vim.cmd("silent edit!")
  has(virt(buf), "12:  45 XP", "after a read the task's new xp:")
  assert(mutate.set(proj.id, { xp = 40 }, { root = root }))
  vim.cmd("silent edit!")

  -- in a buffer with unsaved changes: changed in the buffer, not on disk
  vim.api.nvim_buf_set_lines(buf, 19, 20, false, { "- [ ] 200 XP · Meister ·" })
  local disk = H.read(path_file)
  at(10)
  learn.cmd_xp(ctx({ value = "25" }))
  eq(vim.api.nvim_buf_get_lines(buf, 9, 10, false)[1], "  - [x] Syntax {xp=25}")
  eq(H.read(path_file), disk, "the file on disk as it was")
  vim.cmd("silent edit!")

  -- ── a level reached says so once, in one line ──────────────────────────────
  echoed = {}
  learn.refresh(buf)
  eq(#echoed, 0, "nothing new: no line")
  assert(learn.set_point(buf, 11, "learned"))
  has(table.concat(echoed, "\n"), "[tasks] Level 2 erreicht: Profi", "20 + 50 >= 60: level 2")
  eq(#echoed, 1, "one line")
  learn.refresh(buf)
  learn.refresh(buf)
  eq(#echoed, 1, "and only once")
  eq(said(), "", "no notification (no popup)")
  has(virt(buf), "Level 2 (Profi)" .. DOT .. "Belohnung offen: Eis, Kino")

  -- ── :Tasks reward ──────────────────────────────────────────────────────────
  learn.cmd_reward(ctx({ level = "1" }))
  has(H.read(path_file), "- [x] 20 XP · Einsteiger · Belohnung: Eis\n", "granted: [x]")
  has(said(), "Level 1: Belohnung gegönnt")
  has(virt(buf), "Belohnung offen: Kino", "a granted reward is no longer open")
  lacks(virt(buf), "Eis")
  learn.cmd_reward(ctx({ level = "1" }, { undo = true }))
  has(H.read(path_file), "- [ ] 20 XP · Einsteiger · Belohnung: Eis\n", "undo: [ ] again")
  has(said(), "wieder offen")
  learn.cmd_reward(ctx({ level = "3" }))
  has(said(), "has no reward")
  learn.cmd_reward(ctx({ level = "9" }))
  has(said(), "no such level")
  local task_file =
    F.task(H, root, A, "xp-task", { kind = "task" }, "\n## Lernpunkte\n\n- [ ] a {xp=5}\n")
  local tbuf = open(task_file)
  learn.cmd_reward(ctx({ level = "1" }))
  has(said(), "belong to a learning path")
  -- a task's tree: the XP drawn as well, no level
  learn.attach(tbuf)
  has(virt(tbuf), ":  5 XP")
  has(virt(tbuf), DOT .. "0 / 5 XP")
  lacks(virt(tbuf), "Level")

  -- ── gamification = false hides it all ──────────────────────────────────────
  buf = open(path_file)
  config.merge({ gamification = false })
  learn.refresh(buf)
  v = virt(buf)
  lacks(v, "XP", "no XP")
  lacks(v, "Level", "no level")
  lacks(v, "Belohnung", "no reward")
  has(v, "gelernt", "the progress stays")
  config.merge({ gamification = "yes" })
  has(table.concat(config.ignored(), "\n"), "gamification", "a value that is no boolean is named")
  eq(config.get().gamification, true, "and the default stays")

  -- ── :checkhealth names the state ───────────────────────────────────────────
  local function health()
    local reported = {}
    local real_health = vim.health
    local function rec(msg)
      reported[#reported + 1] = tostring(msg)
    end
    vim.health = { start = rec, ok = rec, warn = rec, error = rec, info = rec }
    pcall(require("tasks_nvim.health").check)
    vim.health = real_health
    return table.concat(reported, "\n")
  end
  config.merge({})
  has(health(), "gamification on")
  config.merge({ gamification = false })
  has(health(), "gamification off")

  config.merge({})
  vim.api.nvim_echo = real_echo
  vim.ui.input = real_input
  vim.notify = real_notify
  vault.set_root(nil)
  vim.cmd("silent! %bwipeout!")
end
